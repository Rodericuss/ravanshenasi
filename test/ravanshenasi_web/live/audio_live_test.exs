defmodule RavanshenasiWeb.AudioLiveTest do
  use RavanshenasiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{AudioMessages, Patients}

  setup %{conn: conn} do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    %{conn: log_in_user(conn, scope.user), scope: scope, patient: patient}
  end

  test "upload cria a msg pending e ela aparece na lista", %{conn: conn, scope: s, patient: p} do
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/audios")

    audio =
      file_input(lv, "#audio-upload-form", :audio, [
        %{name: "a.ogg", content: "fake", type: "audio/ogg"}
      ])

    render_upload(audio, "a.ogg")
    lv |> form("#audio-upload-form", %{"tone" => "empathetic"}) |> render_submit()

    assert [msg] = AudioMessages.list_audio_messages(s, %{id: p.id})
    assert msg.status == :pending
    # data-status é estável e independente de locale (o texto do label é traduzido)
    assert has_element?(lv, "#audio-status-#{msg.id}[data-status=pending]")
  end

  test "broadcast atualiza: transcrevendo → resposta editável", %{
    conn: conn,
    scope: s,
    patient: p
  } do
    # criada ANTES do live/2 → o mount carrega e (conectado) assina o tópico
    {:ok, m} =
      AudioMessages.create_audio_message(s, p, %{
        audio_path: "/tmp/x.ogg",
        original_filename: "a.ogg",
        tone: :empathetic
      })

    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/audios")

    {:ok, _} = AudioMessages.mark_transcribing(s, m)
    assert has_element?(lv, "#audio-status-#{m.id}[data-status=transcribing]")

    {:ok, m} = AudioMessages.save_transcription(s, m, "tô mal", "openai:whisper-1")
    {:ok, _} = AudioMessages.complete(s, m, "Estou aqui.", "openai:gpt")

    assert has_element?(lv, "#transcription-#{m.id}", "tô mal")
    assert has_element?(lv, "#suggested-response-#{m.id}")
    assert has_element?(lv, "#audio-status-#{m.id}[data-status=done]")
  end

  test "clinic admin é barrado pelo live_session :require_clinical", %{conn: conn} do
    admin = clinic_admin_scope_fixture()
    {:ok, p} = Patients.create_patient(therapist_scope_fixture(admin.tenant), %{name: "P"})
    conn = log_in_user(conn, admin.user)
    assert {:error, {:redirect, _}} = live(conn, ~p"/pacientes/#{p.id}/audios")
  end

  test "salvar edição da resposta persiste", %{conn: conn, scope: s, patient: p} do
    {:ok, m} =
      AudioMessages.create_audio_message(s, p, %{
        audio_path: "/tmp/x.ogg",
        original_filename: "a.ogg",
        tone: :empathetic
      })

    {:ok, m} = AudioMessages.save_transcription(s, m, "t", "openai:whisper-1")
    {:ok, _} = AudioMessages.complete(s, m, "original", "openai:gpt")

    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/audios")
    lv |> form("#response-form-#{m.id}", %{"response" => "editada por mim"}) |> render_submit()

    assert AudioMessages.get_audio_message(s, m.id).suggested_response == "editada por mim"
    assert has_element?(lv, "#copy-response-#{m.id}")
  end

  test "retry de erro na etapa 2 (com transcrição) re-enfileira", %{
    conn: conn,
    scope: s,
    patient: p
  } do
    {:ok, m} =
      AudioMessages.create_audio_message(s, p, %{
        audio_path: "/tmp/x.ogg",
        original_filename: "a.ogg",
        tone: :empathetic
      })

    {:ok, m} = AudioMessages.save_transcription(s, m, "t", "openai:whisper-1")
    {:ok, _} = AudioMessages.fail(s, m, :suggestion_failed)

    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/audios")
    lv |> element("#retry-audio-#{m.id}") |> render_click()

    assert AudioMessages.get_audio_message(s, m.id).status == :suggesting
  end
end
