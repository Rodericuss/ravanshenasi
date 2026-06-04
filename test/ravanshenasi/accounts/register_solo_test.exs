defmodule Ravanshenasi.Accounts.RegisterSoloTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts
  alias Ravanshenasi.Accounts.{User, Tenant}

  test "cria tenant solo + user admin atomicamente" do
    attrs = %{name: "Dra. Ana", email: "ana@ex.com", office_name: "Consultório Ana"}

    assert {:ok, %User{} = user} = Accounts.register_solo(attrs)
    assert user.role == :admin
    assert user.name == "Dra. Ana"

    tenant = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.get!(Tenant, user.tenant_id) end)
    assert tenant.plan == :solo
    assert tenant.name == "Consultório Ana"
  end

  test "email duplicado falha" do
    attrs = %{name: "A", email: "dup@ex.com", office_name: "C"}
    assert {:ok, _} = Accounts.register_solo(attrs)
    assert {:error, _} = Accounts.register_solo(%{attrs | name: "B"})
  end
end
