defmodule Ravanshenasi.RLS do
  @moduledoc """
  Migration helper: enables fail-closed RLS on a table.
  The policy compares `column` against the GUC `app.current_tenant_id`,
  with an explicit bypass via `app.auth_bypass = 'on'`.
  """
  import Ecto.Migration

  def enable_tenant_rls(table, column \\ "tenant_id") do
    predicate = tenant_policy_predicate(column)

    execute(
      "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY",
      "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      "CREATE POLICY tenant_isolation ON #{table} USING (#{predicate}) WITH CHECK (#{predicate})",
      "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
    )
  end

  @doc """
  The fail-closed RLS predicate. `NULLIF(..., '')` treats an empty GUC (the
  value left by a `set_config`/`RESET`, which never restores SQL NULL) as
  "no tenant" instead of letting `''::uuid` raise — so reset and never-set both
  fail closed (no rows) rather than erroring.
  """
  def tenant_policy_predicate(column \\ "tenant_id") do
    """
    #{column} = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    OR current_setting('app.auth_bypass', true) = 'on'
    """
  end
end
