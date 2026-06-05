defmodule Ravanshenasi.Analyses.GenerateSuggestionsWorkerTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Analyses, Frameworks, Patients}
  alias Ravanshenasi.Analyses.GenerateSuggestionsWorker

  @json ~s([{"framework":"TCC","justification":"j","techniques":["t"],"watch_out":"w"},
            {"framework":"ACT","justification":"j2","techniques":["t2"],"watch_out":"w2"}])

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria", birth_date: ~D[1990-01-01]})
    fw = Frameworks.list_frameworks(scope) |> hd()
    :ok = Patients.activate_framework(scope, patient, fw)
    {:ok, analysis} = Analyses.analyze_patient(scope, patient)
    %{scope: scope, analysis: analysis}
  end

  test "sucesso → analysis done + suggestions", %{scope: s, analysis: a} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:good],
      providers: %{
        good: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: @json, model: "good"}
      }
    )

    assert :ok = perform_job(GenerateSuggestionsWorker, Analyses.job_args(a))
    done = Analyses.get_analysis(s, a.id)
    assert done.generation_status == :done
    assert done.model_used == "good:good"
    assert length(Analyses.list_suggestions(s, %{id: a.id})) == 2
  end

  test "reexecução de job já concluído é no-op (não duplica cards)", %{scope: s, analysis: a} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:good],
      providers: %{
        good: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: @json, model: "good"}
      }
    )

    assert :ok = perform_job(GenerateSuggestionsWorker, Analyses.job_args(a))
    assert :ok = perform_job(GenerateSuggestionsWorker, Analyses.job_args(a))
    assert length(Analyses.list_suggestions(s, %{id: a.id})) == 2
  end

  test "JSON inválido no último attempt → analysis error", %{scope: s, analysis: a} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad],
      providers: %{
        bad: %{
          client: Ravanshenasi.AI.Client.Stub,
          behavior: :ok,
          content: "sem json",
          model: "bad"
        }
      }
    )

    assert :ok = perform_job(GenerateSuggestionsWorker, Analyses.job_args(a), attempt: 3)
    assert Analyses.get_analysis(s, a.id).generation_status == :error
  end

  test "JSON inválido com attempt < max → {:error, _} (retry)", %{analysis: a} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad],
      providers: %{
        bad: %{
          client: Ravanshenasi.AI.Client.Stub,
          behavior: :ok,
          content: "sem json",
          model: "bad"
        }
      }
    )

    assert {:error, :invalid_json} =
             perform_job(GenerateSuggestionsWorker, Analyses.job_args(a), attempt: 1)
  end
end
