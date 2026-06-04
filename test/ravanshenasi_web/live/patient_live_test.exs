defmodule RavanshenasiWeb.PatientLiveTest do
  use RavanshenasiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures

  setup %{conn: conn} do
    scope = user_scope_fixture()
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  test "cria paciente pelo form e aparece no index", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/pacientes/novo")
    lv |> form("#patient-form", %{"patient" => %{"name" => "Joana"}}) |> render_submit()

    {:ok, _idx, html} = live(conn, ~p"/pacientes")
    assert html =~ "Joana"
  end

  test "busca filtra a lista", %{conn: conn, scope: scope} do
    Ravanshenasi.Patients.create_patient(scope, %{name: "Carlos"})
    Ravanshenasi.Patients.create_patient(scope, %{name: "Daniela"})

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
    {:ok, _} =
      Ravanshenasi.Patients.create_patient(scope, %{name: "Ativo Teste", status: :active})

    {:ok, _} =
      Ravanshenasi.Patients.create_patient(scope, %{name: "Espera Teste", status: :waitlist})

    {:ok, lv, _} = live(conn, ~p"/pacientes")
    html = lv |> form("#patient-filter", %{"status" => "waitlist"}) |> render_change()
    assert html =~ "Espera Teste"
    refute html =~ "Ativo Teste"
  end

  test "inativar paciente na página do perfil atualiza status", %{conn: conn, scope: scope} do
    {:ok, patient} =
      Ravanshenasi.Patients.create_patient(scope, %{name: "Paciente Inativar"})

    {:ok, lv, _} = live(conn, ~p"/pacientes/#{patient.id}")
    assert render(lv) =~ "Inactivate patient"

    lv |> element("button[phx-click='inactivate']") |> render_click()

    reloaded = Ravanshenasi.Patients.get_patient!(scope, patient.id)
    assert reloaded.status == :inactive
  end
end
