defmodule Ravanshenasi.Repo.Migrations.AddUserTenantUniqueIndex do
  use Ecto.Migration

  # Composite-FK target: lets clinical tables reference users (id, tenant_id),
  # enforcing same-tenant ownership at the DB level.
  def change do
    create unique_index(:users, [:id, :tenant_id])
  end
end
