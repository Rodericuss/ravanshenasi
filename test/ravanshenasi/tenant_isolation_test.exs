defmodule Ravanshenasi.TenantIsolationTest do
  use Ravanshenasi.DataCase, async: false
  # async: false intentional: this test exercises transact_tenant/with_*_bypass
  # (transaction + SET LOCAL). Under concurrent Ecto Sandbox this causes races; in
  # production each request uses a short isolated tx, so there is no issue. Serialized on purpose.

  alias Ravanshenasi.Accounts.{Invitation, Scope, Tenant}
  alias Ravanshenasi.Repo

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
    # no transact_tenant/bypass active here → app.current_tenant_id is NULL
    assert Repo.all(Invitation) == []
  end
end
