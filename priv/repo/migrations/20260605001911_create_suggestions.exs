defmodule Ravanshenasi.Repo.Migrations.CreateSuggestions do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:suggestions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      # Derived from the analysis; consistency enforced by the composite FK below.
      add :user_id, :binary_id, null: false
      add :analysis_id, :binary_id, null: false

      add :framework_name, :string, null: false
      add :justification, :text
      add :techniques, {:array, :string}, null: false, default: []
      add :watch_out, :text
      add :status, :string, null: false, default: "suggested"

      timestamps(type: :utc_datetime)
    end

    # Suggestion must not diverge from its analysis's tenant/owner.
    execute(
      "ALTER TABLE suggestions ADD CONSTRAINT suggestions_analysis_owner_fkey FOREIGN KEY (analysis_id, tenant_id, user_id) REFERENCES analyses (id, tenant_id, user_id) ON DELETE CASCADE",
      "ALTER TABLE suggestions DROP CONSTRAINT suggestions_analysis_owner_fkey"
    )

    create index(:suggestions, [:tenant_id, :analysis_id])
    create index(:suggestions, [:tenant_id, :user_id])

    enable_tenant_rls("suggestions")
  end
end
