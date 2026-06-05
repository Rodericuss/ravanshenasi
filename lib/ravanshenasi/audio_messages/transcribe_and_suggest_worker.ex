defmodule Ravanshenasi.AudioMessages.TranscribeAndSuggestWorker do
  @moduledoc "Oban worker: transcribes the audio (Whisper) then suggests a WhatsApp reply (chat)."

  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Ravanshenasi.Accounts.{Scope, Tenant, User}
  alias Ravanshenasi.{AI, AudioMessages, Patients, Records}
  alias Ravanshenasi.AudioMessages.AudioMessage
  alias Ravanshenasi.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max}) do
    %{"audio_message_id" => id, "user_id" => uid, "tenant_id" => tid} = args
    audio_path = args["audio_path"]

    with {:ok, scope} <- build_scope(uid, tid),
         %AudioMessage{} = msg <- AudioMessages.get_audio_message(scope, id) do
      process(scope, msg, audio_path, attempt, max)
    else
      nil -> {:discard, :not_found}
      {:error, :not_found} -> {:discard, :not_found}
    end
  end

  # Terminal (done/error): job já concluído numa execução anterior (at-least-once). No-op.
  defp process(_scope, %AudioMessage{status: st}, _path, _a, _m) when st in [:done, :error],
    do: :ok

  # Transcrição ainda não feita.
  defp process(scope, %AudioMessage{transcription: nil} = msg, audio_path, attempt, max) do
    if is_binary(audio_path) and File.exists?(audio_path) do
      transcribe_step(scope, msg, audio_path, attempt, max)
    else
      # Binário sumiu e não há transcrição: irreversível. Erro terminal, SEM retry.
      {:ok, _} = AudioMessages.fail(scope, msg, :audio_file_missing)
      :ok
    end
  end

  # Transcrição já feita (retry da etapa 2): pula a etapa 1, vai direto pra sugestão.
  defp process(scope, %AudioMessage{} = msg, _audio_path, attempt, max) do
    suggest_step(scope, msg, attempt, max)
  end

  defp transcribe_step(scope, msg, audio_path, attempt, max) do
    {:ok, _} = AudioMessages.mark_transcribing(scope, msg)

    case AI.transcribe(audio_path) do
      {:ok, %{text: text, provider: provider, model: model}} ->
        {:ok, msg} = AudioMessages.save_transcription(scope, msg, text, "#{provider}:#{model}")
        File.rm(audio_path)
        suggest_step(scope, msg, attempt, max)

      {:error, reason} when attempt >= max ->
        # Persiste o reason REAL (erro de API, audio_unreadable, empty_transcription…) pra diagnóstico.
        {:ok, _} = AudioMessages.fail(scope, msg, {:transcription_failed, reason})
        File.rm(audio_path)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp suggest_step(scope, msg, attempt, max) do
    case AI.generate_reply(build_input(scope, msg)) do
      {:ok, %{content: content, provider: provider, model: model}} ->
        {:ok, _} = AudioMessages.complete(scope, msg, content, "#{provider}:#{model}")
        :ok

      {:error, reason} when attempt >= max ->
        {:ok, _} = AudioMessages.fail(scope, msg, {:suggestion_failed, reason})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_input(scope, msg) do
    patient = Patients.get_patient!(scope, msg.patient_id)

    %{
      patient: patient,
      last_record: List.first(Records.recent_done_records(scope, %{id: patient.id}, 1)),
      transcription: msg.transcription,
      tone: msg.tone
    }
  end

  defp build_scope(uid, tid) do
    Repo.with_auth_bypass(fn ->
      with %User{tenant_id: ^tid} = user <- Repo.get(User, uid),
           %Tenant{} = tenant <- Repo.get(Tenant, tid) do
        {:ok, Scope.for_user(user) |> Scope.put_tenant(tenant)}
      else
        _ -> {:error, :not_found}
      end
    end)
  end
end
