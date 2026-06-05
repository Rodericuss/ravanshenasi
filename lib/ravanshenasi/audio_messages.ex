defmodule Ravanshenasi.AudioMessages do
  @moduledoc "WhatsApp audio: transcription + reply suggestion, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.AudioMessages.{AudioMessage, TranscribeAndSuggestWorker}
  alias Ravanshenasi.Patients.Patient
  alias Ravanshenasi.Repo

  @pubsub Ravanshenasi.PubSub

  @doc """
  Creates an audio message. Does not trust the incoming struct: reloads the scoped
  patient, sanitizes the user-provided filename, inserts the pending row, and enqueues
  the worker. Runs inside a single transact_tenant call.
  """
  def create_audio_message(%Scope{} = scope, %{id: patient_id}, attrs) do
    if Scope.clinical_access?(scope),
      do: do_create(scope, patient_id, attrs),
      else: {:error, :unauthorized}
  end

  defp do_create(scope, patient_id, attrs) do
    transact_tenant(scope, fn ->
      case Patient |> patient_scoped(scope) |> Repo.get(patient_id) do
        nil ->
          {:error, :unauthorized}

        _patient ->
          insert_audio_message(scope, patient_id, attrs)
      end
    end)
  end

  defp insert_audio_message(scope, patient_id, attrs) do
    insert =
      %{
        tenant_id: scope.tenant.id,
        user_id: scope.user.id,
        patient_id: patient_id,
        original_filename: sanitize_filename(attrs[:original_filename]),
        tone: attrs[:tone]
      }
      |> AudioMessage.insert_changeset()
      |> Repo.insert()

    case insert do
      {:ok, msg} ->
        Oban.insert!(TranscribeAndSuggestWorker.new(job_args(msg, attrs[:audio_path])))
        {:ok, msg}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Sanitizes the user-provided filename, which may contain clinical data: basename
  # only, up to 255 chars. It is never used as a path; the temp path uses a UUID.
  defp sanitize_filename(name) when is_binary(name),
    do: name |> Path.basename() |> String.slice(0, 255)

  defp sanitize_filename(_), do: "audio"

  def get_audio_message(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> AudioMessage |> scoped(scope) |> Repo.get(id) end)

  def get_audio_message!(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> AudioMessage |> scoped(scope) |> Repo.get!(id) end)

  @doc "Marks the message as transcribing. No-op for done/error states. Broadcasts the result."
  def mark_transcribing(%Scope{} = scope, %{id: id}) do
    update_status(scope, id, fn
      %AudioMessage{status: s} = m when s in [:pending, :transcribing] ->
        AudioMessage.status_changeset(m, %{status: :transcribing})

      %AudioMessage{} = m ->
        # done/error/suggesting are terminal or advanced states; do not regress on re-execution.
        Ecto.Changeset.change(m)
    end)
  end

  @doc "Stores the transcription and transcription_model, moving to :suggesting. No-op if already transcribed."
  def save_transcription(%Scope{} = scope, %{id: id}, text, transcription_model) do
    update_status(scope, id, fn
      %AudioMessage{transcription: nil} = m ->
        AudioMessage.status_changeset(m, %{
          status: :suggesting,
          transcription: text,
          transcription_model: transcription_model
        })

      %AudioMessage{} = m ->
        Ecto.Changeset.change(m)
    end)
  end

  @doc "Stores the suggested response and reply_model_used, moving to :done. No-op if already done."
  def complete(%Scope{} = scope, %{id: id}, suggested_response, reply_model) do
    update_status(scope, id, fn
      %AudioMessage{status: :done} = m ->
        Ecto.Changeset.change(m)

      %AudioMessage{} = m ->
        AudioMessage.status_changeset(m, %{
          status: :done,
          suggested_response: suggested_response,
          reply_model_used: reply_model
        })
    end)
  end

  @doc "Marks the message as error and stores error_reason. No-op if already done."
  def fail(%Scope{} = scope, %{id: id}, reason) do
    update_status(scope, id, fn
      %AudioMessage{status: :done} = m ->
        Ecto.Changeset.change(m)

      %AudioMessage{} = m ->
        AudioMessage.status_changeset(m, %{status: :error, error_reason: inspect(reason)})
    end)
  end

  @doc "Lists the owned patient's audio history, newest first. Reads are scoped by id."
  def list_audio_messages(%Scope{} = scope, %{id: patient_id}) do
    transact_tenant(scope, fn ->
      AudioMessage
      |> scoped(scope)
      |> where([m], m.patient_id == ^patient_id)
      |> order_by([m], desc: m.inserted_at)
      |> Repo.all()
    end)
  end

  @doc "Updates the practitioner's suggested response, only when done. Reloads by scoped id."
  def update_suggested_response(%Scope{} = scope, %{id: id}, text) do
    transact_tenant(scope, fn ->
      case AudioMessage |> scoped(scope) |> Repo.get(id) do
        nil ->
          {:error, :unauthorized}

        %AudioMessage{status: :done} = m ->
          m |> AudioMessage.response_changeset(%{suggested_response: text}) |> Repo.update()

        %AudioMessage{} ->
          {:error, :not_editable}
      end
    end)
  end

  @doc """
  Retries only step 2, the suggestion step. Requires :error plus an existing
  transcription, moves back to :suggesting, and re-enqueues with audio_path: nil so
  step 1 is skipped. Transcription errors without transcription are not retryable and
  require a new upload.
  """
  def retry_suggestion(%Scope{} = scope, %{id: id}) do
    transact_tenant(scope, fn ->
      case AudioMessage |> scoped(scope) |> Repo.get(id) do
        %AudioMessage{status: :error, transcription: t} = m when is_binary(t) ->
          {:ok, m} =
            m
            |> AudioMessage.status_changeset(%{status: :suggesting, error_reason: nil})
            |> Repo.update()

          Oban.insert!(TranscribeAndSuggestWorker.new(job_args(m, nil)))
          {:ok, m}

        %AudioMessage{} ->
          {:error, :not_retryable}

        nil ->
          {:error, :unauthorized}
      end
    end)
  end

  # Reloads by scoped id, applies the transition returned as a changeset, then broadcasts.
  defp update_status(scope, id, fun) do
    res =
      transact_tenant(scope, fn ->
        case AudioMessage |> scoped(scope) |> Repo.get(id) do
          nil -> {:error, :unauthorized}
          m -> m |> fun.() |> Repo.update()
        end
      end)

    with {:ok, m} <- res, do: broadcast(m)
    res
  end

  # --- pubsub / job ---
  def subscribe(audio_message_id),
    do: Phoenix.PubSub.subscribe(@pubsub, "audio:#{audio_message_id}")

  def broadcast(%AudioMessage{} = m),
    do: Phoenix.PubSub.broadcast(@pubsub, "audio:#{m.id}", {:audio_updated, m})

  def job_args(%AudioMessage{} = m, audio_path),
    do: %{
      audio_message_id: m.id,
      user_id: m.user_id,
      tenant_id: m.tenant_id,
      audio_path: audio_path
    }

  @doc "Lists the owner's most recent audios across patients, scoped and preloading :patient."
  def list_recent(%Scope{} = scope, limit \\ 5) do
    transact_tenant(scope, fn ->
      AudioMessage
      |> scoped(scope)
      |> order_by([m], desc: m.inserted_at)
      |> limit(^limit)
      |> preload(:patient)
      |> Repo.all()
    end)
  end

  defp scoped(query, scope),
    do: from(x in query, where: x.tenant_id == ^scope.tenant.id and x.user_id == ^scope.user.id)

  defp patient_scoped(query, scope),
    do: from(p in query, where: p.tenant_id == ^scope.tenant.id and p.user_id == ^scope.user.id)

  defdelegate transact_tenant(scope, fun), to: Repo
end
