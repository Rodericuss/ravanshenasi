defmodule Ravanshenasi.Repo.Migrations.AddTenantFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :restrict), null: false
      add :name, :string, null: false
      add :role, :string, null: false
    end

    create index(:users, [:tenant_id])
  end
end
