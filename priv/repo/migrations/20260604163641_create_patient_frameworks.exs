defmodule Ravanshenasi.Repo.Migrations.CreatePatientFrameworks do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:patient_frameworks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      # Composite FKs: patient AND framework must belong to the same tenant.
      add :patient_id,
          references(:patients,
            type: :binary_id,
            with: [tenant_id: :tenant_id],
            on_delete: :delete_all
          ),
          null: false

      add :thinking_framework_id,
          references(:thinking_frameworks,
            type: :binary_id,
            with: [tenant_id: :tenant_id],
            on_delete: :delete_all
          ),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:patient_frameworks, [:patient_id, :thinking_framework_id])
    create index(:patient_frameworks, [:tenant_id])

    enable_tenant_rls("patient_frameworks")
  end
end
