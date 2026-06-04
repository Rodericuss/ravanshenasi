defmodule RavanshenasiWeb.SessionLiveTest do
  use RavanshenasiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Patients, Records, Sessions}

  setup %{conn: conn} do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    %{conn: log_in_user(conn, scope.user), scope: scope, patient: patient}
  end

  test "cria sessão e finaliza mostra 'gerando'", %{conn: conn, scope: s, patient: p} do
    {:ok, sess} = Sessions.create_session(s, p, %{notes: "n"})
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/sessoes/#{sess.id}")
    html = lv |> element("button[phx-click='finalize']") |> render_click()
    assert html =~ "Generating" or html =~ "generating"
  end

  test "broadcast done atualiza a tela", %{conn: conn, scope: s, patient: p} do
    {:ok, sess} = Sessions.create_session(s, p, %{notes: "n"})
    {:ok, %{record: rec}} = Sessions.finalize_session(s, sess)
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/sessoes/#{sess.id}")
    {:ok, _} = Records.complete(s, rec, "S: pronto\nO:..\nA:..\nP:..", "stub:stub-model")
    assert render(lv) =~ "pronto"
  end
end
