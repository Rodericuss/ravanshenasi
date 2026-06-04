defmodule Ravanshenasi.RepoTransactTenantTest do
  use Ravanshenasi.DataCase, async: false
  # async: false proposital: este teste exercita transact_tenant/with_*_bypass
  # (transaction + SET LOCAL). Sob o Ecto Sandbox concorrente isso tem race; em
  # produção cada request usa tx curta isolada, sem o problema. Serializado de propósito.

  alias Ravanshenasi.Repo
  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Accounts.Tenant

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
end
