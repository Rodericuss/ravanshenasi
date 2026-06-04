defmodule Ravanshenasi.Repo.Migrations.CreatePatients do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:patients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      # Composite FK: owner must be a user OF THE SAME TENANT.
      add :user_id,
          references(:users, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :restrict),
          null: false

      add :name, :string, null: false
      add :birth_date, :date
      add :phone, :string
      add :email, :string
      add :chief_complaint, :text
      add :relevant_history, :text
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create index(:patients, [:tenant_id, :user_id])
    create index(:patients, [:tenant_id, :user_id, :status])
    create index(:patients, [:tenant_id, :user_id, :name])
    # Composite-FK target for patient_frameworks (later task).
    create unique_index(:patients, [:id, :tenant_id])

    enable_tenant_rls("patients")
  end
end
