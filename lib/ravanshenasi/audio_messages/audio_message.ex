defmodule Ravanshenasi.AudioMessages.AudioMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audio_messages" do
    field :original_filename, :string
    field :tone, Ecto.Enum, values: [:empathetic, :informative, :encouraging]
    field :transcription, :string
    field :suggested_response, :string

    field :status, Ecto.Enum,
      values: [:pending, :transcribing, :suggesting, :done, :error],
      default: :pending

    field :transcription_model, :string
    field :reply_model_used, :string
    field :error_reason, :string

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User
    belongs_to :patient, Ravanshenasi.Patients.Patient

    timestamps(type: :utc_datetime)
  end

  @doc "Insert changeset (pending). tone/tenant/user/patient/filename são server-side."
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:tenant_id, :user_id, :patient_id, :original_filename, :tone])
    |> validate_required([:tenant_id, :user_id, :patient_id, :original_filename, :tone])
  end

  @doc "Status/etapas (transcrição, sugestão, erro)."
  def status_changeset(audio_message, attrs) do
    cast(audio_message, attrs, [
      :status,
      :transcription,
      :suggested_response,
      :transcription_model,
      :reply_model_used,
      :error_reason
    ])
  end

  @doc "Edição da resposta sugerida pelo profissional."
  def response_changeset(audio_message, attrs) do
    audio_message
    |> cast(attrs, [:suggested_response])
    |> validate_required([:suggested_response])
  end
end
