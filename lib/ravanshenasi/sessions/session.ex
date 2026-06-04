defmodule Ravanshenasi.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sessions" do
    field :date, :utc_datetime
    field :duration_minutes, :integer
    field :notes, :string
    field :status, Ecto.Enum, values: [:draft, :finalized], default: :draft

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User
    belongs_to :patient, Ravanshenasi.Patients.Patient

    timestamps(type: :utc_datetime)
  end

  @doc "Campos editáveis pelo profissional (tenant_id/user_id/patient_id setados server-side)."
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:date, :duration_minutes, :notes, :status])
    |> validate_required([])
  end
end
