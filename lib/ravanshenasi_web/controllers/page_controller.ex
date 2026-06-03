defmodule RavanshenasiWeb.PageController do
  use RavanshenasiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
