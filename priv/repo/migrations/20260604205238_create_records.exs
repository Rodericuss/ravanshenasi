defmodule Ravanshenasi.Repo.Migrations.CreateRecords do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, :binary_id, null: false
      add :session_id, :binary_id, null: false
      add :patient_id, :binary_id, null: false

      add :content, :text
      add :reviewed, :boolean, null: false, default: false
      add :generation_status, :string, null: false, default: "pending"
      add :model_used, :string
      add :error_reason, :string

      timestamps(type: :utc_datetime)
    end

    # FKs compostas record↔session (integridade: record não diverge da sua sessão)
    execute(
      "ALTER TABLE records ADD CONSTRAINT records_session_owner_fkey FOREIGN KEY (session_id, tenant_id, user_id) REFERENCES sessions (id, tenant_id, user_id) ON DELETE CASCADE",
      "ALTER TABLE records DROP CONSTRAINT records_session_owner_fkey"
    )

    execute(
      "ALTER TABLE records ADD CONSTRAINT records_session_patient_fkey FOREIGN KEY (session_id, patient_id) REFERENCES sessions (id, patient_id) ON DELETE CASCADE",
      "ALTER TABLE records DROP CONSTRAINT records_session_patient_fkey"
    )

    create unique_index(:records, [:session_id])
    create index(:records, [:tenant_id, :user_id])
    create index(:records, [:tenant_id, :patient_id])

    enable_tenant_rls("records")
  end
end
