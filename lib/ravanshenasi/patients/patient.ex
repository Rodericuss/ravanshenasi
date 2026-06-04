defmodule Ravanshenasi.Patients.Patient do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "patients" do
    field :name, :string
    field :birth_date, :date
    field :phone, :string
    field :email, :string
    field :chief_complaint, :string
    field :relevant_history, :string
    field :status, Ecto.Enum, values: [:active, :inactive, :waitlist], default: :active

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "User-editable fields (tenant_id/user_id are set server-side, never from the form)."
  def changeset(patient, attrs) do
    patient
    |> cast(attrs, [:name, :birth_date, :phone, :email, :chief_complaint, :relevant_history, :status])
    |> validate_required([:name])
  end
end
