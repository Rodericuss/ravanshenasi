defmodule Ravanshenasi.Accounts.TenantTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts.Tenant

  test "changeset exige name e plan válido" do
    cs = Tenant.changeset(%Tenant{}, %{name: "Clínica X", plan: :clinic})
    assert cs.valid?
  end

  test "changeset rejeita plan fora do enum" do
    cs = Tenant.changeset(%Tenant{}, %{name: "X", plan: :enterprise})
    refute cs.valid?
    assert %{plan: ["is invalid"]} = errors_on(cs)
  end

  test "changeset exige name" do
    cs = Tenant.changeset(%Tenant{}, %{plan: :solo})
    refute cs.valid?
    assert %{name: ["can't be blank"]} = errors_on(cs)
  end
end
