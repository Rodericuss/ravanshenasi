defmodule Ravanshenasi.Repo.Migrations.EnableTenantRls do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    enable_tenant_rls("tenants", "id")
    enable_tenant_rls("users")
    enable_tenant_rls("invitations")
    # users_tokens fica FORA do RLS-por-tenant (sem tenant_id) — protegida por token + scope.
  end
end
