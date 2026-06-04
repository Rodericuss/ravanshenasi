defmodule Ravanshenasi.Accounts.RegisterClinicTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts
  alias Ravanshenasi.Accounts.{User, Tenant}

  test "cria tenant clinic + user admin (gestor)" do
    attrs = %{clinic_name: "Clínica Z", name: "Admin Z", email: "admin@z.com"}

    assert {:ok, %User{} = user} = Accounts.register_clinic(attrs)
    assert user.role == :admin

    tenant = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.get!(Tenant, user.tenant_id) end)
    assert tenant.plan == :clinic
    assert tenant.name == "Clínica Z"
  end
end
