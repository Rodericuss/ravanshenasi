defmodule Ravanshenasi.AnalysesTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Analyses, Frameworks, Patients}
  alias Ravanshenasi.Analyses.GenerateSuggestionsWorker

  @suggestions [
    %{framework: "TCC", justification: "j1", techniques: ["t1"], watch_out: "w1"},
    %{framework: "ACT", justification: "j2", techniques: ["t2", "t3"], watch_out: "w2"}
  ]

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    framework = Frameworks.list_frameworks(scope) |> hd()
    :ok = Patients.activate_framework(scope, patient, framework)
    %{scope: scope, patient: patient}
  end

  test "analyze_patient cria pending + enfileira job", %{scope: s, patient: p} do
    assert {:ok, analysis} = Analyses.analyze_patient(s, p)
    assert analysis.generation_status == :pending
    assert_enqueued(worker: GenerateSuggestionsWorker, args: %{analysis_id: analysis.id})
  end

  test "analyze_patient sem frameworks ativos → :no_active_frameworks (sem job)" do
    s = user_scope_fixture()
    {:ok, p} = Patients.create_patient(s, %{name: "Sem Linha"})
    assert {:error, :no_active_frameworks} = Analyses.analyze_patient(s, p)
    assert [] = all_enqueued(worker: GenerateSuggestionsWorker)
  end

  test "analyze_patient é idempotente: 2ª chamada devolve a ativa, sem 2º job", %{
    scope: s,
    patient: p
  } do
    assert {:ok, a1} = Analyses.analyze_patient(s, p)
    assert {:ok, a2} = Analyses.analyze_patient(s, p)
    assert a1.id == a2.id
    assert [_one] = all_enqueued(worker: GenerateSuggestionsWorker)
  end

  test "analyze_patient de paciente de OUTRO profissional → :unauthorized" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})

    assert {:error, :unauthorized} = Analyses.analyze_patient(b, pa)
  end

  test "admin de clínica não tem acesso clínico → :unauthorized", %{patient: p} do
    admin = clinic_admin_scope_fixture()
    assert {:error, :unauthorized} = Analyses.analyze_patient(admin, p)
  end

  test "get_analysis escopa por dono", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    assert Analyses.get_analysis(s, a.id).id == a.id

    other = user_scope_fixture()
    assert Analyses.get_analysis(other, a.id) == nil
  end

  test "mark_generating → generating + broadcast", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    Analyses.subscribe(a.id)
    assert {:ok, a} = Analyses.mark_generating(s, a)
    assert a.generation_status == :generating
    assert_receive {:analysis_updated, %{generation_status: :generating}}
  end

  test "complete grava done + insere N suggestions + broadcast", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    Analyses.subscribe(a.id)
    assert {:ok, done} = Analyses.complete(s, a, @suggestions, "stub:stub-model")
    assert done.generation_status == :done
    assert done.model_used == "stub:stub-model"
    cards = Analyses.list_suggestions(s, %{id: a.id})
    assert length(cards) == 2
    assert Enum.map(cards, & &1.framework_name) |> Enum.sort() == ["ACT", "TCC"]
    assert Enum.all?(cards, &(&1.status == :suggested))
    assert_receive {:analysis_updated, %{generation_status: :done}}
  end

  test "fail grava error + error_reason", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    assert {:ok, a} = Analyses.fail(s, a, :invalid_json)
    assert a.generation_status == :error
    assert a.error_reason =~ "invalid_json"
  end

  test "complete 2x (reexecução de job) NÃO duplica cards", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    {:ok, _} = Analyses.complete(s, a, @suggestions, "stub:m")
    {:ok, again} = Analyses.complete(s, a, @suggestions, "stub:m")
    assert again.generation_status == :done
    assert length(Analyses.list_suggestions(s, %{id: a.id})) == 2
  end

  test "mark_generating em análise já done NÃO regride", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    {:ok, _} = Analyses.complete(s, a, @suggestions, "stub:m")
    assert {:ok, still_done} = Analyses.mark_generating(s, a)
    assert still_done.generation_status == :done
  end

  test "list_analyses do paciente, do dono; não vaza pra outro therapist do tenant" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})
    fw = Frameworks.list_frameworks(a) |> hd()
    :ok = Patients.activate_framework(a, pa, fw)
    {:ok, an} = Analyses.analyze_patient(a, pa)

    assert Enum.map(Analyses.list_analyses(a, %{id: pa.id}), & &1.id) == [an.id]
    # B passa o id do paciente de A — não enxerga as análises de A
    assert Analyses.list_analyses(b, %{id: pa.id}) == []
  end

  test "list_suggestions não vaza pra outro profissional", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    {:ok, _} = Analyses.complete(s, a, @suggestions, "stub:m")

    assert length(Analyses.list_suggestions(s, %{id: a.id})) == 2
    other = user_scope_fixture()
    assert Analyses.list_suggestions(other, %{id: a.id}) == []
  end

  test "save_suggestion / discard_suggestion mudam status; alheio → :unauthorized", %{
    scope: s,
    patient: p
  } do
    {:ok, a} = Analyses.analyze_patient(s, p)
    {:ok, _} = Analyses.complete(s, a, @suggestions, "stub:m")
    [c1, c2] = Analyses.list_suggestions(s, %{id: a.id})

    assert {:ok, saved} = Analyses.save_suggestion(s, c1)
    assert saved.status == :saved
    assert {:ok, disc} = Analyses.discard_suggestion(s, c2)
    assert disc.status == :discarded

    other = user_scope_fixture()
    assert {:error, :unauthorized} = Analyses.save_suggestion(other, c1)
  end
end
