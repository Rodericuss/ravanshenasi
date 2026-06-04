defmodule Ravanshenasi.Accounts.RegisterSoloTest do
  use Ravanshenasi.DataCase, async: false
  # async: false intentional: this test exercises transact_tenant/with_*_bypass
  # (transaction + SET LOCAL). Under concurrent Ecto Sandbox this causes races; in
  # production each request uses a short isolated tx, so there is no issue. Serialized on purpose.

  alias Ravanshenasi.Accounts
  alias Ravanshenasi.Accounts.{Tenant, User}

  test "cria tenant solo + user admin atomicamente" do
    attrs = %{name: "Dra. Ana", email: "ana@ex.com", office_name: "Consultório Ana"}

    assert {:ok, %User{} = user} = Accounts.register_solo(attrs)
    assert user.role == :admin
    assert user.name == "Dra. Ana"

    tenant =
      Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.get!(Tenant, user.tenant_id) end)

    assert tenant.plan == :solo
    assert tenant.name == "Consultório Ana"
  end

  test "email duplicado falha" do
    attrs = %{name: "A", email: "dup@ex.com", office_name: "C"}
    assert {:ok, _} = Accounts.register_solo(attrs)
    assert {:error, _} = Accounts.register_solo(%{attrs | name: "B"})
  end

  test "exige email" do
    assert {:error, cs} = Accounts.register_solo(%{name: "A", email: "", office_name: "C"})
    assert %{email: ["can't be blank"]} = errors_on(cs)
  end

  test "valida formato do email" do
    assert {:error, cs} =
             Accounts.register_solo(%{name: "A", email: "not valid", office_name: "C"})

    assert %{email: ["must have the @ sign and no spaces"]} = errors_on(cs)
  end

  test "valida tamanho máximo do email" do
    too_long = String.duplicate("db", 100) <> "@ex.com"
    assert {:error, cs} = Accounts.register_solo(%{name: "A", email: too_long, office_name: "C"})
    assert "should be at most 160 character(s)" in errors_on(cs).email
  end
end
