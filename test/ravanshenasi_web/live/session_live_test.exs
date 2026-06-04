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
    lv |> element("#finalize-session-button") |> render_click()
    assert has_element?(lv, "#record-generating")
  end

  test "broadcast done atualiza a tela", %{conn: conn, scope: s, patient: p} do
    {:ok, sess} = Sessions.create_session(s, p, %{notes: "n"})
    {:ok, %{record: rec}} = Sessions.finalize_session(s, sess)
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/sessoes/#{sess.id}")
    {:ok, _} = Records.complete(s, rec, "S: pronto\nO:..\nA:..\nP:..", "stub:stub-model")
    assert has_element?(lv, "#soap-record-content", "pronto")
  end
end
