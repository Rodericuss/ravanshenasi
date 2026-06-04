defmodule Ravanshenasi.RLS do
  @moduledoc """
  Helper de migration: liga RLS fail-closed numa tabela.
  Policy compara `column` com o GUC `app.current_tenant_id`,
  com bypass explícito via `app.auth_bypass = 'on'`.
  """
  import Ecto.Migration

  def enable_tenant_rls(table, column \\ "tenant_id") do
    predicate = """
    #{column} = current_setting('app.current_tenant_id', true)::uuid
    OR current_setting('app.auth_bypass', true) = 'on'
    """

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
end
