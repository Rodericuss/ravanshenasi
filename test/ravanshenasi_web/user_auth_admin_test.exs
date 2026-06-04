defmodule RavanshenasiWeb.UserAuthAdminTest do
  use RavanshenasiWeb.ConnCase, async: true

  alias RavanshenasiWeb.UserAuth
  alias Ravanshenasi.Accounts.Scope

  test "require_admin deixa passar admin", %{conn: conn} do
    {:ok, admin} = Ravanshenasi.Accounts.register_clinic(%{clinic_name: "C", name: "A", email: "a@c.com"})
    admin = Ravanshenasi.Repo.preload(admin, :tenant)
    scope = Scope.for_user(admin) |> Scope.put_tenant(admin.tenant)

    conn = conn |> Plug.Conn.assign(:current_scope, scope) |> UserAuth.require_admin([])
    refute conn.halted
  end

  test "require_admin barra therapist", %{conn: conn} do
    scope = Scope.for_user(%Ravanshenasi.Accounts.User{role: :therapist})

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> fetch_flash()
      |> Plug.Conn.assign(:current_scope, scope)
      |> UserAuth.require_admin([])

    assert conn.halted
  end
end
