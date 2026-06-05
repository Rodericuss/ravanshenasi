defmodule RavanshenasiWeb.DashboardLiveTest do
  use RavanshenasiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{AudioMessages, Patients, Records, Sessions}

  setup %{conn: conn} do
    scope = user_scope_fixture()
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  test "vazio: mostra empty states e contagens zero", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/painel")
    assert has_element?(lv, "#card-pending-review")
    assert has_element?(lv, "#card-active-patients")
    assert render(lv) =~ "0"
  end

  test "renderiza cards com dados do dono + links corretos", %{conn: conn, scope: s} do
    {:ok, p} = Patients.create_patient(s, %{name: "Marcos"})
    {:ok, sess} = Sessions.create_session(s, p, %{notes: "n", date: ~U[2026-05-01 10:00:00Z]})
    {:ok, %{record: rec}} = Sessions.finalize_session(s, sess)
    {:ok, _} = Records.complete(s, rec, "S:..\nP:..", "stub:m")

    {:ok, audio} =
      AudioMessages.create_audio_message(s, p, %{
        audio_path: "/tmp/x.ogg",
        original_filename: "msg.ogg",
        tone: :empathetic
      })

    {:ok, lv, _} = live(conn, ~p"/painel")

    # prontuário pendente: nome do paciente + link pra sessão
    assert has_element?(lv, "#pending-review-#{rec.id}", "Marcos")

    assert has_element?(
             lv,
             ~s{#pending-review-#{rec.id} a[href="/pacientes/#{p.id}/sessoes/#{sess.id}"]}
           )

    # áudio recente: filename + link
    assert has_element?(lv, "#recent-audio-#{audio.id}", "msg.ogg")
    assert has_element?(lv, ~s{#recent-audio-#{audio.id} a[href="/pacientes/#{p.id}/audios"]})

    # sessão recente + paciente ativo
    assert has_element?(
             lv,
             ~s{#recent-session-#{sess.id} a[href="/pacientes/#{p.id}/sessoes/#{sess.id}"]}
           )

    assert has_element?(lv, ~s{#active-patient-#{p.id} a[href="/pacientes/#{p.id}"]})
  end

  test "não vaza dados de outro profissional do mesmo tenant", %{conn: conn} do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "Paciente de A"})

    conn_b = log_in_user(conn, b.user)
    {:ok, lv, _} = live(conn_b, ~p"/painel")
    refute render(lv) =~ "Paciente de A"
    refute has_element?(lv, "#active-patient-#{pa.id}")
  end

  test "clinic admin é barrado pelo live_session :require_clinical", %{conn: conn} do
    admin = clinic_admin_scope_fixture()
    conn = log_in_user(conn, admin.user)
    assert {:error, {:redirect, _}} = live(conn, ~p"/painel")
  end

  test "header mostra o link pro painel pro clínico", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/painel")
    assert has_element?(lv, ~s{a[href="/painel"]})
  end
end
