defmodule Ravanshenasi.AudioMessagesTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{AudioMessages, Patients}
  alias Ravanshenasi.AudioMessages.TranscribeAndSuggestWorker

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    %{scope: scope, patient: patient}
  end

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{audio_path: "/tmp/x.ogg", original_filename: "audio.ogg", tone: :empathetic},
      extra
    )
  end

  test "create_audio_message cria pending + enfileira job", %{scope: s, patient: p} do
    assert {:ok, msg} = AudioMessages.create_audio_message(s, p, attrs())
    assert msg.status == :pending
    assert msg.tone == :empathetic
    assert_enqueued(worker: TranscribeAndSuggestWorker, args: %{audio_message_id: msg.id})
  end

  test "sanitiza original_filename (basename, sem path)", %{scope: s, patient: p} do
    {:ok, msg} =
      AudioMessages.create_audio_message(
        s,
        p,
        attrs(%{original_filename: "/etc/passwd/../áudio do João.ogg"})
      )

    refute msg.original_filename =~ "/"
    assert msg.original_filename == "áudio do João.ogg"
  end

  test "tom inválido (string fora da whitelist) → erro, sem job", %{scope: s, patient: p} do
    assert {:error, %Ecto.Changeset{}} =
             AudioMessages.create_audio_message(s, p, attrs(%{tone: "hacker"}))

    assert [] = all_enqueued(worker: TranscribeAndSuggestWorker)
  end

  test "paciente de OUTRO profissional → :unauthorized" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})

    assert {:error, :unauthorized} =
             AudioMessages.create_audio_message(b, pa, %{
               audio_path: "/tmp/x.ogg",
               original_filename: "a.ogg",
               tone: :empathetic
             })
  end

  test "admin de clínica → :unauthorized", %{patient: p} do
    admin = clinic_admin_scope_fixture()

    assert {:error, :unauthorized} =
             AudioMessages.create_audio_message(admin, p, %{
               audio_path: "/tmp/x.ogg",
               original_filename: "a.ogg",
               tone: :empathetic
             })
  end

  test "get_audio_message escopa por dono", %{scope: s, patient: p} do
    {:ok, msg} = AudioMessages.create_audio_message(s, p, attrs())
    assert AudioMessages.get_audio_message(s, msg.id).id == msg.id
    other = user_scope_fixture()
    assert AudioMessages.get_audio_message(other, msg.id) == nil
  end

  test "fluxo transcrição→sugestão grava campos + broadcast + idempotência", %{
    scope: s,
    patient: p
  } do
    {:ok, m} = AudioMessages.create_audio_message(s, p, attrs())
    AudioMessages.subscribe(m.id)

    assert {:ok, m} = AudioMessages.mark_transcribing(s, m)
    assert m.status == :transcribing
    assert_receive {:audio_updated, %{status: :transcribing}}

    assert {:ok, m} = AudioMessages.save_transcription(s, m, "tô mal", "openai:whisper-1")
    assert m.status == :suggesting and m.transcription == "tô mal"
    assert m.transcription_model == "openai:whisper-1"

    assert {:ok, done} = AudioMessages.complete(s, m, "Estou aqui com você.", "openai:gpt")
    assert done.status == :done and done.suggested_response == "Estou aqui com você."
    assert done.reply_model_used == "openai:gpt"

    # idempotência: complete de novo é no-op (não muda nem duplica)
    assert {:ok, again} = AudioMessages.complete(s, done, "OUTRO", "openai:gpt")
    assert again.suggested_response == "Estou aqui com você."

    # mark_transcribing em done não regride
    assert {:ok, still} = AudioMessages.mark_transcribing(s, done)
    assert still.status == :done
  end

  test "fail grava error + error_reason", %{scope: s, patient: p} do
    {:ok, m} = AudioMessages.create_audio_message(s, p, attrs())
    assert {:ok, m} = AudioMessages.fail(s, m, :audio_file_missing)
    assert m.status == :error and m.error_reason =~ "audio_file_missing"
  end

  test "list_audio_messages do paciente do dono; não vaza pra outro therapist" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})

    {:ok, m} =
      AudioMessages.create_audio_message(a, pa, %{
        audio_path: "/tmp/x.ogg",
        original_filename: "a.ogg",
        tone: :empathetic
      })

    assert Enum.map(AudioMessages.list_audio_messages(a, %{id: pa.id}), & &1.id) == [m.id]
    assert AudioMessages.list_audio_messages(b, %{id: pa.id}) == []
  end

  test "update_suggested_response edita só quando :done; alheio → :unauthorized", %{
    scope: s,
    patient: p
  } do
    {:ok, m} = AudioMessages.create_audio_message(s, p, attrs())
    {:ok, m} = AudioMessages.save_transcription(s, m, "t", "openai:whisper-1")
    {:ok, m} = AudioMessages.complete(s, m, "resposta", "openai:gpt")

    assert {:ok, edited} = AudioMessages.update_suggested_response(s, m, "minha edição")
    assert edited.suggested_response == "minha edição"

    other = user_scope_fixture()
    assert {:error, :unauthorized} = AudioMessages.update_suggested_response(other, m, "hack")
  end

  test "retry_suggestion só com :error + transcrição: volta a :suggesting e re-enfileira", %{
    scope: s,
    patient: p
  } do
    {:ok, m} = AudioMessages.create_audio_message(s, p, attrs())
    {:ok, m} = AudioMessages.save_transcription(s, m, "t", "openai:whisper-1")
    {:ok, m} = AudioMessages.fail(s, m, :provider_down)

    assert {:ok, retried} = AudioMessages.retry_suggestion(s, m)
    assert retried.status == :suggesting
    assert_enqueued(worker: TranscribeAndSuggestWorker, args: %{audio_message_id: m.id})
  end

  test "retry_suggestion sem transcrição (erro na etapa 1) → {:error, :not_retryable}", %{
    scope: s,
    patient: p
  } do
    {:ok, m} = AudioMessages.create_audio_message(s, p, attrs())
    {:ok, m} = AudioMessages.fail(s, m, :audio_file_missing)
    assert {:error, :not_retryable} = AudioMessages.retry_suggestion(s, m)
  end
end
