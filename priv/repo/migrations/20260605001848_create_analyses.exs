defmodule Ravanshenasi.Repo.Migrations.CreateAnalyses do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:analyses, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      # Composite FK: owner must be a user OF THE SAME TENANT.
      add :user_id,
          references(:users,
            type: :binary_id,
            with: [tenant_id: :tenant_id],
            on_delete: :restrict
          ),
          null: false

      # 3-column composite FK added via raw SQL below (references/with: only does 2 cols).
      add :patient_id, :binary_id, null: false

      add :generation_status, :string, null: false, default: "pending"
      add :model_used, :string
      add :error_reason, :string

      timestamps(type: :utc_datetime)
    end

    # Ties patient to the SAME tenant AND owner: the DB rejects an analysis whose
    # patient belongs to another practitioner. Target: patients (id, tenant_id, user_id).
    execute(
      "ALTER TABLE analyses ADD CONSTRAINT analyses_patient_owner_fkey FOREIGN KEY (patient_id, tenant_id, user_id) REFERENCES patients (id, tenant_id, user_id) ON DELETE CASCADE",
      "ALTER TABLE analyses DROP CONSTRAINT analyses_patient_owner_fkey"
    )

    create index(:analyses, [:tenant_id, :user_id])
    create index(:analyses, [:tenant_id, :patient_id])
    # Composite-FK target for suggestions.analysis_id.
    create unique_index(:analyses, [:id, :tenant_id, :user_id])

    # Partial unique index: at most ONE active (pending|generating) analysis per patient.
    # Net against double-click races; the changeset declares this constraint name.
    create unique_index(:analyses, [:tenant_id, :user_id, :patient_id],
             where: "generation_status IN ('pending','generating')",
             name: :analyses_one_active_per_patient
           )

    enable_tenant_rls("analyses")
  end
end
