defmodule Ravanshenasi.Repo.Migrations.HardenTenantPolicyNullif do
  use Ecto.Migration

  # Recreate the tenant_isolation policy so the GUC is read via NULLIF(..., '').
  # Resetting a custom GUC (set_config/RESET) leaves it as '' (never SQL NULL),
  # and ''::uuid raises instead of failing closed. NULLIF maps '' -> NULL so an
  # empty/reset tenant GUC yields zero rows, matching the never-set case.

  @new_predicate """
  tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
  OR current_setting('app.auth_bypass', true) = 'on'
  """

  @old_predicate """
  tenant_id = current_setting('app.current_tenant_id', true)::uuid
  OR current_setting('app.auth_bypass', true) = 'on'
  """

  def up, do: recreate_policy(@new_predicate)
  def down, do: recreate_policy(@old_predicate)

  defp recreate_policy(predicate) do
    execute("DROP POLICY IF EXISTS tenant_isolation ON invitations")

    execute(
      "CREATE POLICY tenant_isolation ON invitations USING (#{predicate}) WITH CHECK (#{predicate})"
    )
  end
end
