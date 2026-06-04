defmodule Ravanshenasi.Accounts.RegisterClinicTest do
  use Ravanshenasi.DataCase, async: false
  # async: false intentional: this test exercises transact_tenant/with_*_bypass
  # (transaction + SET LOCAL). Under concurrent Ecto Sandbox this causes races; in
  # production each request uses a short isolated tx, so there is no issue. Serialized on purpose.

  alias Ravanshenasi.Accounts
  alias Ravanshenasi.Accounts.{Tenant, User}

  test "cria tenant clinic + user admin (gestor)" do
    attrs = %{clinic_name: "Clínica Z", name: "Admin Z", email: "admin@z.com"}

    assert {:ok, %User{} = user} = Accounts.register_clinic(attrs)
    assert user.role == :admin

    tenant =
      Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.get!(Tenant, user.tenant_id) end)

    assert tenant.plan == :clinic
    assert tenant.name == "Clínica Z"
  end

  test "define senha quando password é informado" do
    attrs = %{
      clinic_name: "Clínica P",
      name: "Admin P",
      email: "admin-pwd@p.com",
      password: "supersecret123"
    }

    assert {:ok, %User{} = user} = Accounts.register_clinic(attrs)
    assert is_binary(user.hashed_password)
    assert User.valid_password?(user, "supersecret123")
  end

  test "sem password fica só-magic-link (hashed_password nil)" do
    attrs = %{clinic_name: "Clínica N", name: "Admin N", email: "admin-nopwd@n.com"}

    assert {:ok, %User{} = user} = Accounts.register_clinic(attrs)
    assert is_nil(user.hashed_password)
  end
end
