defmodule RavanshenasiWeb.OrgFlowsTest do
  use RavanshenasiWeb.ConnCase, async: false
  # async: false: the acceptance flow uses accept_invitation (with_*_bypass internally),
  # which is flaky in parallel under the Ecto Sandbox. Serialized on purpose.
  import Phoenix.LiveViewTest

  alias Ravanshenasi.Accounts
  alias Ravanshenasi.Accounts.{Scope, User, UserToken}
  alias Ravanshenasi.Repo

  test "registro de clínica cria conta admin", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/registrar/clinica")

    lv
    |> form("#clinic-registration-form",
      clinic: %{clinic_name: "Clínica Y", name: "Dona Y", email: "dona@y.com"}
    )
    |> render_submit()

    user = Repo.get_by(User, email: "dona@y.com")
    assert user.role == :admin
    # confirmation magic link sent (same as solo registration): login token created
    assert Repo.get_by(UserToken, user_id: user.id, context: "login")
  end

  test "admin convida e membro aceita", %{conn: conn} do
    {:ok, admin} =
      Accounts.register_clinic(%{clinic_name: "C", name: "A", email: "admin@c.com"})

    admin = Repo.preload(admin, :tenant)

    scope =
      Scope.for_user(admin)
      |> Scope.put_tenant(admin.tenant)

    {:ok, raw} =
      Accounts.create_invitation(scope, %{email: "membro@c.com", role: :therapist})

    {:ok, lv, _html} = live(conn, ~p"/convites/#{raw}")

    result =
      lv
      |> form("#accept-invitation-form", user: %{name: "Membro", password: "supersecret123"})
      |> render_submit()

    # redirects to the magic link flow that establishes the session
    assert {:error, {:redirect, %{to: "/users/log-in/" <> _token}}} = result

    member = Repo.get_by(User, email: "membro@c.com")
    assert member.role == :therapist
    assert member.tenant_id == admin.tenant_id
    # invitation proves email ownership → member is created already confirmed (no limbo)
    assert member.confirmed_at
  end

  test "usuário já logado é redirecionado ao abrir um convite", %{conn: conn} do
    {:ok, admin} =
      Accounts.register_clinic(%{clinic_name: "C2", name: "A2", email: "admin2@c.com"})

    admin = Repo.preload(admin, :tenant)

    scope =
      Scope.for_user(admin)
      |> Scope.put_tenant(admin.tenant)

    {:ok, raw} =
      Accounts.create_invitation(scope, %{email: "outro@c.com", role: :therapist})

    assert {:error, {:redirect, _}} =
             conn
             |> log_in_user(admin)
             |> live(~p"/convites/#{raw}")
  end
end
