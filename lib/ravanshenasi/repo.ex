defmodule Ravanshenasi.Repo do
  use Ecto.Repo,
    otp_app: :ravanshenasi,
    adapter: Ecto.Adapters.Postgres

  alias Ravanshenasi.Accounts.Scope

  @doc """
  Roda `fun` dentro de uma transação com `app.current_tenant_id` setado
  (SET LOCAL) para o tenant do scope. Retorna o resultado CRU de `fun.()`
  (não `{:ok, _}`). Levanta com scope sem tenant válido.
  """
  def transact_tenant(%Scope{tenant: %{id: id}}, fun) when is_function(fun, 0) do
    {:ok, result} =
      transaction(fn ->
        set_local("app.current_tenant_id", id)
        fun.()
      end)

    result
  end

  def transact_tenant(%Scope{tenant: nil}, _fun) do
    raise ArgumentError, "transact_tenant requer um %Scope{} com tenant carregado"
  end

  @doc "Bypass de RLS para os 3 lookups pré-tenant (login por email, token de sessão, invitation por token)."
  def with_auth_bypass(fun) when is_function(fun, 0), do: do_bypass(fun)

  @doc "Bypass de RLS para criação pré-tenant (INSERT de tenant/user no registro e aceite)."
  def with_registration_bypass(fun) when is_function(fun, 0), do: do_bypass(fun)

  @doc """
  Executa um `Ecto.Multi` com bypass de RLS ativo.
  Não aninha transações — o Multi é a transação principal, e o SET LOCAL é
  emitido via `Multi.run` no início da mesma transação.
  Retorna `{:ok, map}` ou `{:error, step, changeset, changes_so_far}`.
  """
  def with_registration_bypass_multi(%Ecto.Multi{} = multi) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:__bypass_on__, fn repo, _ ->
      repo.query!("SELECT set_config('app.auth_bypass', 'on', true)")
      {:ok, :bypassed}
    end)
    |> Ecto.Multi.append(multi)
    |> transaction()
  end

  defp do_bypass(fun) do
    {:ok, result} =
      transaction(fn ->
        set_local("app.auth_bypass", "on")

        try do
          fun.()
        after
          # Reset explícito: sob a transação longa do Sandbox (testes), garante que
          # o bypass não vaze pros asserts seguintes. Em produção é redundante (a
          # transação fecha logo), mas inofensivo.
          set_local("app.auth_bypass", "off")
        end
      end)

    result
  end

  # is_local = true → vale só na transação atual; em produção a transação é curta
  # (um checkout do pool), então o GUC nunca vaza entre requests.
  defp set_local(key, value) do
    query!("SELECT set_config($1, $2, true)", [key, to_string(value)])
  end
end
