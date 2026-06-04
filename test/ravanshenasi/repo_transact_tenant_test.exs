defmodule Ravanshenasi.RepoTransactTenantTest do
  use Ravanshenasi.DataCase, async: false
  # async: false intentional: this test exercises transact_tenant/with_*_bypass
  # (transaction + SET LOCAL). Under concurrent Ecto Sandbox this causes races; in
  # production each request uses a short isolated tx, so there is no issue. Serialized on purpose.

  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Accounts.Tenant
  alias Ravanshenasi.Repo

  defp scope_for(tenant), do: %Scope{tenant: tenant}

  test "retorna o resultado CRU da função (não {:ok, _})" do
    tenant = %Tenant{id: Ecto.UUID.generate()}
    result = Repo.transact_tenant(scope_for(tenant), fn -> 42 end)
    assert result == 42
  end

  test "seta app.current_tenant_id dentro do bloco" do
    id = Ecto.UUID.generate()
    tenant = %Tenant{id: id}

    got =
      Repo.transact_tenant(scope_for(tenant), fn ->
        %{rows: [[v]]} = Repo.query!("SELECT current_setting('app.current_tenant_id', true)")
        v
      end)

    assert got == id
  end

  test "levanta com scope sem tenant" do
    assert_raise ArgumentError, fn ->
      Repo.transact_tenant(%Scope{tenant: nil}, fn -> :nope end)
    end
  end

  test "reseta app.current_tenant_id após o bloco (não vaza no Sandbox)" do
    tenant = %Tenant{id: Ecto.UUID.generate()}
    Repo.transact_tenant(scope_for(tenant), fn -> :ok end)

    %{rows: [[v]]} = Repo.query!("SELECT current_setting('app.current_tenant_id', true)")
    assert v in [nil, ""], "esperava GUC resetado após transact_tenant, vazou: #{inspect(v)}"
  end
end
