defmodule Ravanshenasi.Repo.Migrations.CreateSessions do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :user_id,
          references(:users,
            type: :binary_id,
            with: [tenant_id: :tenant_id],
            on_delete: :restrict
          ),
          null: false

      add :patient_id,
          references(:patients,
            type: :binary_id,
            with: [tenant_id: :tenant_id],
            on_delete: :delete_all
          ),
          null: false

      add :date, :utc_datetime
      add :duration_minutes, :integer
      add :notes, :text
      add :status, :string, null: false, default: "draft"

      timestamps(type: :utc_datetime)
    end

    create index(:sessions, [:tenant_id, :user_id])
    create index(:sessions, [:tenant_id, :patient_id])
    create index(:sessions, [:tenant_id, :user_id, :status])
    # alvos das FKs compostas do record (Task 3)
    create unique_index(:sessions, [:id, :tenant_id, :user_id])
    create unique_index(:sessions, [:id, :patient_id])

    enable_tenant_rls("sessions")
  end
end
