defmodule Ravanshenasi.Repo do
  use Ecto.Repo,
    otp_app: :ravanshenasi,
    adapter: Ecto.Adapters.Postgres

  alias Ravanshenasi.Accounts.Scope

  @doc """
  Runs `fun` inside a transaction with `app.current_tenant_id` set
  (SET LOCAL) to the scope's tenant. Returns the raw result of `fun.()`
  (not `{:ok, _}`). Raises if the scope has no loaded tenant.
  """
  def transact_tenant(%Scope{tenant: %{id: id}}, fun) when is_function(fun, 0) do
    transaction(fn ->
      set_local("app.current_tenant_id", id)
      fun.()
    end)
    |> unwrap_transaction()
  end

  def transact_tenant(%Scope{tenant: nil}, _fun) do
    raise ArgumentError, "transact_tenant requer um %Scope{} com tenant carregado"
  end

  @doc "RLS bypass for the 3 pre-tenant lookups (login by email, session token, invitation by token)."
  def with_auth_bypass(fun) when is_function(fun, 0), do: do_bypass(fun)

  @doc "RLS bypass for pre-tenant creation (INSERT of tenant/user during registration and invitation acceptance)."
  def with_registration_bypass(fun) when is_function(fun, 0), do: do_bypass(fun)

  @doc """
  Runs an `Ecto.Multi` with the RLS bypass active.
  Does not nest transactions — the Multi is the main transaction, and SET LOCAL is
  emitted via `Multi.run` at the start of the same transaction.
  Returns `{:ok, map}` or `{:error, step, changeset, changes_so_far}`.
  """
  def with_registration_bypass_multi(%Ecto.Multi{} = multi) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:__bypass_on__, fn repo, _ ->
      repo.query!("SELECT set_config('app.auth_bypass', 'on', true)")
      {:ok, :bypassed}
    end)
    |> Ecto.Multi.append(multi)
    |> Ecto.Multi.run(:__bypass_off__, fn repo, _ ->
      # Reset on the SUCCESS path: under the Sandbox's long-running transaction (tests),
      # RELEASE of the savepoint does NOT revert SET LOCAL, so the bypass would leak into
      # subsequent asserts. On the ERROR path, ROLLBACK of the savepoint already reverts
      # 'on', so only the success case needs to be covered here. In production this is
      # redundant (the transaction closes right away), but harmless.
      repo.query!("SELECT set_config('app.auth_bypass', 'off', true)")
      {:ok, :reset}
    end)
    |> transaction()
  end

  defp do_bypass(fun) do
    transaction(fn ->
      set_local("app.auth_bypass", "on")

      try do
        fun.()
      after
        # Explicit reset: under the Sandbox's long-running transaction (tests), ensures
        # the bypass does not leak into subsequent asserts. In production this is
        # redundant (the transaction closes right away), but harmless.
        set_local("app.auth_bypass", "off")
      end
    end)
    |> unwrap_transaction()
  end

  # Unwraps the result of transaction/1. `{:error, reason}` only occurs with
  # an explicit `Repo.rollback/1` (which we don't use); if it happens, raises with
  # context instead of a cryptic MatchError.
  defp unwrap_transaction({:ok, result}), do: result

  defp unwrap_transaction({:error, reason}) do
    raise "Ravanshenasi.Repo: transação revertida inesperadamente: #{inspect(reason)}"
  end

  # is_local = true → applies only to the current transaction; in production the transaction
  # is short (a single pool checkout), so the GUC never leaks across requests.
  defp set_local(key, value) do
    query!("SELECT set_config($1, $2, true)", [key, to_string(value)])
  end
end
