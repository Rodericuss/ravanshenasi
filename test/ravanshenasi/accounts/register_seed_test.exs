defmodule Ravanshenasi.Accounts.RegisterSeedTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.{Accounts, Frameworks}
  alias Ravanshenasi.Accounts.Scope

  defp scope_of(user) do
    user = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.preload(user, :tenant) end)
    Scope.for_user(user) |> Scope.put_tenant(user.tenant)
  end

  test "register_solo cria 7 frameworks de catálogo" do
    {:ok, user} =
      Accounts.register_solo(%{
        name: "A",
        email: "solo#{System.unique_integer()}@ex.com",
        office_name: "C"
      })

    assert length(Frameworks.list_frameworks(scope_of(user))) == 7
  end

  test "register_clinic cria 7 frameworks de catálogo" do
    {:ok, user} =
      Accounts.register_clinic(%{
        clinic_name: "C",
        name: "A",
        email: "cli#{System.unique_integer()}@ex.com"
      })

    assert length(Frameworks.list_frameworks(scope_of(user))) == 7
  end

  test "accept_invitation NÃO duplica catálogo (therapist herda)" do
    admin = clinic_admin_scope_fixture()

    {:ok, raw} =
      Accounts.create_invitation(admin, %{
        email: "m#{System.unique_integer()}@ex.com",
        role: :therapist
      })

    {:ok, member} = Accounts.accept_invitation(raw, %{name: "M", password: "supersecret123"})
    # vê os 7 do tenant, nenhum próprio
    assert length(Frameworks.list_frameworks(scope_of(member))) == 7
  end
end
