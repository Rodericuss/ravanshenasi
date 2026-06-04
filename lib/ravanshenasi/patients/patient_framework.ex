defmodule Ravanshenasi.Patients.PatientFramework do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "patient_frameworks" do
    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :patient, Ravanshenasi.Patients.Patient
    belongs_to :thinking_framework, Ravanshenasi.Frameworks.ThinkingFramework

    timestamps(type: :utc_datetime)
  end

  def changeset(pf, attrs) do
    pf
    |> cast(attrs, [:tenant_id, :patient_id, :thinking_framework_id])
    |> validate_required([:tenant_id, :patient_id, :thinking_framework_id])
    |> unique_constraint([:patient_id, :thinking_framework_id])
  end
end
