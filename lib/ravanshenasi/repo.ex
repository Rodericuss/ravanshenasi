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

  # is_local = true → vale só na transação atual; em produção a transação é curta
  # (um checkout do pool), então o GUC nunca vaza entre requests.
  defp set_local(key, value) do
    query!("SELECT set_config($1, $2, true)", [key, to_string(value)])
  end
end
