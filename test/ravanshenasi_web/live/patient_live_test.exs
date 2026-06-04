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
end
