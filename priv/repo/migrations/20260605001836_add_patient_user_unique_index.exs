defmodule Ravanshenasi.Repo.Migrations.AddPatientUserUniqueIndex do
  use Ecto.Migration

  def change do
    # Composite-FK target for analyses.patient_id (id, tenant_id, user_id) — ties an
    # analysis's patient to the SAME owner. Patients today only have (id, tenant_id).
    create unique_index(:patients, [:id, :tenant_id, :user_id])
  end
end
