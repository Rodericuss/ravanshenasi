defmodule Ravanshenasi.AudioMessages.TranscribeAndSuggestWorkerTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{AudioMessages, Patients}
  alias Ravanshenasi.AudioMessages.TranscribeAndSuggestWorker

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    # arquivo de áudio temporário real (o worker vai apagá-lo após transcrever)
    path = Path.join(System.tmp_dir!(), "wav_#{System.unique_integer([:positive])}.ogg")
    File.write!(path, "fake")

    {:ok, msg} =
      AudioMessages.create_audio_message(scope, patient, %{
        audio_path: path,
        original_filename: "a.ogg",
        tone: :empathetic
      })

    on_exit(fn -> File.rm(path) end)
    %{scope: scope, msg: msg, path: path}
  end

  defp args(msg, path),
    do: %{
      "audio_message_id" => msg.id,
      "user_id" => msg.user_id,
      "tenant_id" => msg.tenant_id,
      "audio_path" => path
    }

  test "sucesso nas 2 etapas → done + transcrição + resposta + binário apagado", %{
    scope: s,
    msg: m,
    path: path
  } do
    # stub: transcrição "olá, tudo bem?" (config/test.exs) + chat "stub..." (config/test.exs)
    assert :ok = perform_job(TranscribeAndSuggestWorker, args(m, path))
    done = AudioMessages.get_audio_message(s, m.id)
    assert done.status == :done
    assert done.transcription == "olá, tudo bem?"
    assert is_binary(done.suggested_response) and done.suggested_response != ""
    assert done.transcription_model == "stub:stub-model" or done.transcription_model =~ "stub"
    refute File.exists?(path)
  end

  test "binário sumiu (audio_path inexistente) + sem transcrição → error :audio_file_missing terminal",
       %{scope: s, msg: m} do
    assert :ok = perform_job(TranscribeAndSuggestWorker, args(m, "/nao/existe.ogg"))
    failed = AudioMessages.get_audio_message(s, m.id)
    assert failed.status == :error
    assert failed.error_reason =~ "audio_file_missing"
  end

  test "reexecução de job já done é no-op (não duplica/regride)", %{scope: s, msg: m, path: path} do
    assert :ok = perform_job(TranscribeAndSuggestWorker, args(m, path))
    assert :ok = perform_job(TranscribeAndSuggestWorker, args(m, "/qualquer.ogg"))
    assert AudioMessages.get_audio_message(s, m.id).status == :done
  end

  test "falha na transcrição no último attempt → error", %{scope: s, msg: m, path: path} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(
      :ravanshenasi,
      Ravanshenasi.AI,
      Keyword.merge(prev,
        transcription: %{
          order: [:bad],
          providers: %{
            bad: %{client: Ravanshenasi.AI.Transcriber.Stub, behavior: :error, model: "bad"}
          }
        }
      )
    )

    assert :ok = perform_job(TranscribeAndSuggestWorker, args(m, path), attempt: 3)
    failed = AudioMessages.get_audio_message(s, m.id)
    assert failed.status == :error
    # o reason real do provider é preservado pra diagnóstico (não só :transcription_failed)
    assert failed.error_reason =~ "transcription_failed"
  end
end
