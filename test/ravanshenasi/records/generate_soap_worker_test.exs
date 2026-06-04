defmodule Ravanshenasi.Records.GenerateSoapWorkerTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Patients, Records, Sessions}
  alias Ravanshenasi.Records.{GenerateSoapWorker, Record}

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria", birth_date: ~D[1990-01-01]})
    {:ok, session} = Sessions.create_session(scope, patient, %{notes: "notas de hoje"})

    {:ok, record} =
      Ravanshenasi.Repo.transact_tenant(scope, fn ->
        %Record{
          tenant_id: scope.tenant.id,
          user_id: scope.user.id,
          session_id: session.id,
          patient_id: patient.id,
          generation_status: :pending
        }
        |> Ecto.Changeset.change()
        |> Ravanshenasi.Repo.insert()
      end)

    %{scope: scope, record: record}
  end

  test "sucesso → record done + content + model_used", %{scope: s, record: r} do
    assert :ok = perform_job(GenerateSoapWorker, Records.job_args(r))
    done = Records.get_record(s, r.id)
    assert done.generation_status == :done
    assert is_binary(done.content) and done.content != ""
    assert done.model_used == "stub:stub-model"
  end

  test "erro no último attempt → record error", %{scope: s, record: r} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad],
      providers: %{bad: %{client: Ravanshenasi.AI.Client.Stub, behavior: :error, model: "bad"}}
    )

    assert :ok = perform_job(GenerateSoapWorker, Records.job_args(r), attempt: 3)
    assert Records.get_record(s, r.id).generation_status == :error
  end
end
