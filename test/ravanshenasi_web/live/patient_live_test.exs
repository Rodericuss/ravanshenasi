defmodule RavanshenasiWeb.PatientLiveTest do
  use RavanshenasiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Analyses, Frameworks, Patients}

  setup %{conn: conn} do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    %{conn: log_in_user(conn, scope.user), scope: scope, patient: patient}
  end

  test "cria paciente pelo form e aparece no index", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/pacientes/novo")
    lv |> form("#patient-form", %{"patient" => %{"name" => "Joana"}}) |> render_submit()

    {:ok, _idx, html} = live(conn, ~p"/pacientes")
    assert html =~ "Joana"
  end

  test "busca filtra a lista", %{conn: conn, scope: scope} do
    Patients.create_patient(scope, %{name: "Carlos"})
    Patients.create_patient(scope, %{name: "Daniela"})

    {:ok, lv, _} = live(conn, ~p"/pacientes")
    html = lv |> form("#patient-search", %{"q" => "carl"}) |> render_change()
    assert html =~ "Carlos"
    refute html =~ "Daniela"
  end

  test "clinic-admin é barrado de /pacientes pelo gate clínico" do
    scope = clinic_admin_scope_fixture()
    conn = build_conn() |> log_in_user(scope.user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/pacientes")
  end

  test "filtro de status exibe só pacientes do status selecionado", %{conn: conn, scope: scope} do
    {:ok, _} = Patients.create_patient(scope, %{name: "Ativo Teste", status: :active})
    {:ok, _} = Patients.create_patient(scope, %{name: "Espera Teste", status: :waitlist})

    {:ok, lv, _} = live(conn, ~p"/pacientes")
    html = lv |> form("#patient-filter", %{"status" => "waitlist"}) |> render_change()
    assert html =~ "Espera Teste"
    refute html =~ "Ativo Teste"
  end

  test "inativar paciente na página do perfil atualiza status", %{conn: conn, scope: scope} do
    {:ok, patient} = Patients.create_patient(scope, %{name: "Paciente Inativar"})

    {:ok, lv, _} = live(conn, ~p"/pacientes/#{patient.id}")
    assert render(lv) =~ "Inactivate patient"

    lv |> element("button[phx-click='inactivate']") |> render_click()

    reloaded = Patients.get_patient!(scope, patient.id)
    assert reloaded.status == :inactive
  end

  # --- Fatia 3 / Task 15: UI de sugestões ---

  @suggestions [
    %{framework: "TCC", justification: "j1", techniques: ["t1"], watch_out: "w1"},
    %{framework: "ACT", justification: "j2", techniques: ["t2"], watch_out: "w2"}
  ]

  defp activate_one(scope, patient) do
    fw = Frameworks.list_frameworks(scope) |> hd()
    :ok = Patients.activate_framework(scope, patient, fw)
  end

  test "sem frameworks: analisar mostra empty state", %{conn: conn, patient: p} do
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}")
    lv |> element("#analyze-patient-button") |> render_click()
    assert has_element?(lv, "#no-frameworks-warning")
  end

  test "com frameworks: analisar mostra 'Analisando'", %{conn: conn, scope: s, patient: p} do
    activate_one(s, p)
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}")
    lv |> element("#analyze-patient-button") |> render_click()
    assert has_element?(lv, "#analysis-generating")
  end

  test "broadcast done renderiza os cards", %{conn: conn, scope: s, patient: p} do
    activate_one(s, p)
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}")
    lv |> element("#analyze-patient-button") |> render_click()

    [analysis] = Analyses.list_analyses(s, %{id: p.id})
    {:ok, _} = Analyses.complete(s, analysis, @suggestions, "stub:stub-model")

    assert has_element?(lv, "#suggestions")
    assert has_element?(lv, "h4", "TCC")
  end

  test "salvar um card muda o estado", %{conn: conn, scope: s, patient: p} do
    activate_one(s, p)
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}")
    lv |> element("#analyze-patient-button") |> render_click()
    [analysis] = Analyses.list_analyses(s, %{id: p.id})
    {:ok, _} = Analyses.complete(s, analysis, @suggestions, "stub:m")

    [c1, _] = Analyses.list_suggestions(s, %{id: analysis.id})
    lv |> element("#save-suggestion-#{c1.id}") |> render_click()
    assert Analyses.list_suggestions(s, %{id: analysis.id}) |> Enum.any?(&(&1.status == :saved))
  end
end
