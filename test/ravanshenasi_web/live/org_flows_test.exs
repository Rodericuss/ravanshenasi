defmodule RavanshenasiWeb.OrgFlowsTest do
  use RavanshenasiWeb.ConnCase, async: false
  # async: false: o fluxo de aceite usa accept_invitation (with_*_bypass no corpo),
  # que é flaky em paralelo sob o Ecto Sandbox. Serializado de propósito.
  import Phoenix.LiveViewTest

  alias Ravanshenasi.Accounts
  alias Ravanshenasi.Accounts.{Scope, User}
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

    lv
    |> form("#accept-invitation-form", user: %{name: "Membro", password: "supersecret123"})
    |> render_submit()

    member = Repo.get_by(User, email: "membro@c.com")
    assert member.role == :therapist
    assert member.tenant_id == admin.tenant_id
  end
end
