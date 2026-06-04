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

  test "solo pode deletar linha própria e ela some da lista", %{conn: conn} do
    scope = user_scope_fixture()
    conn = log_in_user(conn, scope.user)
    {:ok, fw} = Ravanshenasi.Frameworks.create_own_framework(scope, %{name: "Linha Deletar"})

    {:ok, lv, html} = live(conn, ~p"/linhas")
    assert html =~ "Linha Deletar"

    lv |> element("button[phx-click='delete'][phx-value-id='#{fw.id}']") |> render_click()

    refute render(lv) =~ "Linha Deletar"
  end

  test "solo pode editar linha própria e o novo nome aparece", %{conn: conn} do
    scope = user_scope_fixture()
    conn = log_in_user(conn, scope.user)
    {:ok, fw} = Ravanshenasi.Frameworks.create_own_framework(scope, %{name: "Linha Original"})

    {:ok, lv, _} = live(conn, ~p"/linhas")

    lv |> element("button[phx-click='edit'][phx-value-id='#{fw.id}']") |> render_click()

    html =
      lv
      |> form("#framework-edit-form-#{fw.id} form", %{
        "framework" => %{"name" => "Linha Editada"}
      })
      |> render_submit()

    assert html =~ "Linha Editada"
    refute html =~ "Linha Original"
  end
end
