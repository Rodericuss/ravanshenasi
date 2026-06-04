defmodule Ravanshenasi.Accounts.InvitationsTest do
  use Ravanshenasi.DataCase, async: false
  # async: false intentional: this test exercises transact_tenant/with_*_bypass
  # (transaction + SET LOCAL). Under concurrent Ecto Sandbox this causes races; in
  # production each request uses a short isolated tx, so there is no issue. Serialized on purpose.

  alias Ravanshenasi.Accounts
  alias Ravanshenasi.Accounts.{Scope, User}

  setup do
    {:ok, admin} =
      Accounts.register_clinic(%{clinic_name: "C", name: "Admin", email: "admin@c.com"})

    admin = Ravanshenasi.Repo.preload(admin, :tenant)
    %{admin: admin, scope: Scope.for_user(admin) |> Scope.put_tenant(admin.tenant)}
  end

  test "create_invitation gera token e o aceite cria therapist no tenant certo", %{
    admin: admin,
    scope: scope
  } do
    assert {:ok, raw_token} =
             Accounts.create_invitation(scope, %{email: "novo@c.com", role: :therapist})

    assert {:ok, %User{} = member} =
             Accounts.accept_invitation(raw_token, %{name: "Novo", password: "supersecret123"})

    assert member.role == :therapist
    assert member.tenant_id == admin.tenant_id
    assert member.email == "novo@c.com"
  end

  test "token inválido falha" do
    assert {:error, :invalid_invitation} = Accounts.accept_invitation("naoexiste", %{name: "X"})
  end

  test "create_invitation barra admin de tenant solo (convite é só de clínica)" do
    {:ok, solo} =
      Accounts.register_solo(%{name: "Solo", email: "solo@s.com", office_name: "Consult Solo"})

    solo = Ravanshenasi.Repo.preload(solo, :tenant)
    solo_scope = Scope.for_user(solo) |> Scope.put_tenant(solo.tenant)

    assert_raise MatchError, fn ->
      Accounts.create_invitation(solo_scope, %{email: "x@s.com", role: :therapist})
    end
  end

  test "convite expirado falha", %{scope: scope} do
    {:ok, raw} = Accounts.create_invitation(scope, %{email: "exp@c.com", role: :therapist})

    Ravanshenasi.Repo.with_auth_bypass(fn ->
      Ravanshenasi.Repo.update_all(Ravanshenasi.Accounts.Invitation,
        set: [expires_at: ~U[2000-01-01 00:00:00Z]]
      )
    end)

    assert {:error, :expired} =
             Accounts.accept_invitation(raw, %{name: "X", password: "supersecret123"})
  end
end
