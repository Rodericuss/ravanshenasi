defmodule Ravanshenasi.Repo.Migrations.CreateThinkingFrameworks do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:thinking_frameworks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      # Composite FK: own frameworks belong to a user OF THE SAME TENANT.
      # user_id NULL = tenant catalog; MATCH SIMPLE skips the FK check when null.
      add :user_id,
          references(:users,
            type: :binary_id,
            with: [tenant_id: :tenant_id],
            on_delete: :delete_all
          )

      add :name, :string, null: false
      add :description, :text
      add :is_predefined, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:thinking_frameworks, [:tenant_id, :user_id])
    # Composite-FK target for patient_frameworks.
    create unique_index(:thinking_frameworks, [:id, :tenant_id])
    # No duplicate name within the catalog (user_id NULL) or within one user's own.
    create unique_index(:thinking_frameworks, [:tenant_id, :user_id, :name],
             nulls_distinct: false,
             name: :thinking_frameworks_tenant_user_name_index
           )

    enable_tenant_rls("thinking_frameworks")
  end
end
