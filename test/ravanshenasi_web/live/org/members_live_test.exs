defmodule RavanshenasiWeb.Org.MembersLiveTest do
  use RavanshenasiWeb.ConnCase, async: false
  # async: false intentional: exercises register_solo/clinic (transact + SET LOCAL).

  import Phoenix.LiveViewTest

  alias Ravanshenasi.Accounts

  test "solo-admin é barrado em /equipe (convite é só de clínica)", %{conn: conn} do
    {:ok, solo} =
      Accounts.register_solo(%{name: "Solo", email: "solo@equipe.com", office_name: "C"})

    conn = log_in_user(conn, solo)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/equipe")
  end

  test "clinic-admin acessa /equipe", %{conn: conn} do
    {:ok, admin} =
      Accounts.register_clinic(%{clinic_name: "C", name: "Admin", email: "admin@equipe.com"})

    conn = log_in_user(conn, admin)

    assert {:ok, _lv, html} = live(conn, ~p"/equipe")
    assert html =~ "equipe" or html =~ "Equipe" or html =~ "Team"
  end
end
