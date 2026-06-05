defmodule Ravanshenasi.AudioMessages.AudioMessageTest do
  use ExUnit.Case, async: true
  alias Ravanshenasi.AudioMessages.AudioMessage

  test "insert_changeset válido nasce pending" do
    cs =
      AudioMessage.insert_changeset(%{
        tenant_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        patient_id: Ecto.UUID.generate(),
        original_filename: "audio.ogg",
        tone: :empathetic
      })

    assert cs.valid?
    assert Ecto.Changeset.apply_changes(cs).status == :pending
  end

  test "tone fora da whitelist → inválido" do
    cs =
      AudioMessage.insert_changeset(%{
        tenant_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        patient_id: Ecto.UUID.generate(),
        original_filename: "a.ogg",
        tone: :hacker
      })

    refute cs.valid?
  end

  test "status_changeset altera status/transcription/models/erro" do
    cs =
      AudioMessage.status_changeset(%AudioMessage{}, %{
        status: :done,
        transcription: "t",
        transcription_model: "openai:whisper-1",
        reply_model_used: "openai:gpt"
      })

    assert Ecto.Changeset.apply_changes(cs).status == :done
  end
end
