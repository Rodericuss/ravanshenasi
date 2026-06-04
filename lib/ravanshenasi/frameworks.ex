defmodule Ravanshenasi.Frameworks do
  @moduledoc "Therapeutic lines of thought: tenant catalog + practitioner's own."

  import Ecto.Query

  alias Ravanshenasi.Repo
  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Frameworks.{Defaults, ThinkingFramework}

  @doc "The 7 predefined lines (name + description)."
  def default_frameworks, do: Defaults.all()

  @doc "Lines visible to the scope: tenant catalog (user_id NULL) ∪ own (user_id = self)."
  def list_frameworks(%Scope{} = scope) do
    uid = scope.user.id

    transact_tenant(scope, fn ->
      Repo.all(
        from f in ThinkingFramework,
          where: is_nil(f.user_id) or f.user_id == ^uid,
          order_by: [asc: f.name]
      )
    end)
  end

  def get_framework!(%Scope{} = scope, id) do
    uid = scope.user.id

    transact_tenant(scope, fn ->
      Repo.one!(
        from f in ThinkingFramework,
          where: f.id == ^id and (is_nil(f.user_id) or f.user_id == ^uid)
      )
    end)
  end

  @doc "Creates a tenant-catalog line (user_id NULL). Requires admin."
  def create_tenant_framework(%Scope{} = scope, attrs) do
    if Scope.admin?(scope) do
      insert_framework(scope, attrs, nil)
    else
      {:error, :unauthorized}
    end
  end

  @doc "Creates the practitioner's own line (user_id = self). Requires clinical access."
  def create_own_framework(%Scope{} = scope, attrs) do
    if Scope.clinical_access?(scope) do
      insert_framework(scope, attrs, scope.user.id)
    else
      {:error, :unauthorized}
    end
  end

  defp insert_framework(scope, attrs, user_id) do
    transact_tenant(scope, fn ->
      %ThinkingFramework{tenant_id: scope.tenant.id, user_id: user_id}
      |> ThinkingFramework.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @doc "Updates a line. Catalog lines require admin; own lines require clinical access."
  def update_framework(%Scope{} = scope, %ThinkingFramework{} = fw, attrs) do
    if can_manage?(scope, fw) do
      transact_tenant(scope, fn -> fw |> ThinkingFramework.changeset(attrs) |> Repo.update() end)
    else
      {:error, :unauthorized}
    end
  end

  @doc "Deletes a line (cascade removes patient associations)."
  def delete_framework(%Scope{} = scope, %ThinkingFramework{} = fw) do
    if can_manage?(scope, fw) do
      transact_tenant(scope, fn -> Repo.delete(fw) end)
    else
      {:error, :unauthorized}
    end
  end

  defp can_manage?(scope, %ThinkingFramework{user_id: nil}), do: Scope.admin?(scope)
  defp can_manage?(scope, %ThinkingFramework{user_id: uid}), do: scope.user.id == uid and Scope.clinical_access?(scope)

  # Inserts the 7 default lines at tenant level (user_id NULL). Runs inside the
  # registration Multi (bypass active). `repo` is the dynamic repo of the Multi.
  @doc false
  def seed_tenant_defaults(repo, tenant_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(Defaults.all(), fn attrs ->
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          user_id: nil,
          name: attrs.name,
          description: attrs.description,
          is_predefined: true,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo.insert_all(ThinkingFramework, rows)
    :ok
  end

  defdelegate transact_tenant(scope, fun), to: Repo
end
