defmodule RavanshenasiWeb.FrameworkLiveTest do
  use RavanshenasiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures

  test "solo cria linha própria e ela aparece", %{conn: conn} do
    scope = user_scope_fixture()
    conn = log_in_user(conn, scope.user)
    {:ok, lv, _} = live(conn, ~p"/linhas")

    html =
      lv
      |> form("#framework-form", %{"framework" => %{"name" => "Sistêmica", "description" => "x"}})
      |> render_submit()

    assert html =~ "Sistêmica"
  end
end
