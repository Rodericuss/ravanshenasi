defmodule Ravanshenasi.Records.Record do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "records" do
    field :content, :string
    field :reviewed, :boolean, default: false

    field :generation_status, Ecto.Enum,
      values: [:pending, :generating, :done, :error],
      default: :pending

    field :model_used, :string
    field :error_reason, :string

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User
    belongs_to :session, Ravanshenasi.Sessions.Session
    belongs_to :patient, Ravanshenasi.Patients.Patient

    timestamps(type: :utc_datetime)
  end

  @doc "Content update changeset for review edits."
  def content_changeset(record, attrs) do
    record |> cast(attrs, [:content, :reviewed]) |> validate_required([:content])
  end

  @doc "Generation status transition changeset."
  def status_changeset(record, attrs) do
    record |> cast(attrs, [:generation_status, :content, :model_used, :error_reason])
  end
end
