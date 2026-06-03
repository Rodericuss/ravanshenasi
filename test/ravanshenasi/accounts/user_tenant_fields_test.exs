defmodule Ravanshenasi.Accounts.UserTenantFieldsTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts.User

  test "tenant_changeset exige tenant_id, name e role válido" do
    cs = User.tenant_changeset(%User{}, %{tenant_id: Ecto.UUID.generate(), name: "Dra. Ana", role: :therapist})
    assert cs.valid?
  end

  test "tenant_changeset rejeita role fora do enum" do
    cs = User.tenant_changeset(%User{}, %{tenant_id: Ecto.UUID.generate(), name: "X", role: :root})
    refute cs.valid?
    assert %{role: ["is invalid"]} = errors_on(cs)
  end
end
