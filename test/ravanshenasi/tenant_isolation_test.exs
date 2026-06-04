defmodule Ravanshenasi.TenantIsolationTest do
  use Ravanshenasi.DataCase, async: false
  # async: false proposital: este teste exercita transact_tenant/with_*_bypass
  # (transaction + SET LOCAL). Sob o Ecto Sandbox concorrente isso tem race; em
  # produção cada request usa tx curta isolada, sem o problema. Serializado de propósito.

  alias Ravanshenasi.Repo
  alias Ravanshenasi.Accounts.{Scope, Tenant, Invitation}

  setup do
    {:ok, ta} =
      Repo.with_registration_bypass(fn -> Repo.insert(%Tenant{name: "A", plan: :clinic}) end)

    {:ok, tb} =
      Repo.with_registration_bypass(fn -> Repo.insert(%Tenant{name: "B", plan: :clinic}) end)

    insert_inv = fn tenant, email ->
      {_raw, cs} =
        Invitation.build(%{email: email, role: :therapist},
          tenant_id: tenant.id,
          invited_by_user_id: nil
        )

      {:ok, inv} = Repo.with_registration_bypass(fn -> Repo.insert(cs) end)
      inv
    end

    insert_inv.(ta, "a1@ex.com")
    insert_inv.(tb, "b1@ex.com")

    %{tenant_a: ta, tenant_b: tb}
  end

  test "RLS: dentro de transact_tenant(A) só enxerga invitations do tenant A", %{tenant_a: ta} do
    emails =
      Repo.transact_tenant(%Scope{tenant: ta}, fn ->
        Repo.all(Invitation) |> Enum.map(& &1.email)
      end)

    assert emails == ["a1@ex.com"]
  end

  test "RLS fail-closed: sem GUC de tenant, query direta retorna 0 linhas" do
    # nenhum transact_tenant/bypass ativo aqui → app.current_tenant_id é NULL
    assert Repo.all(Invitation) == []
  end
end
