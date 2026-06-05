defmodule RavanshenasiWeb.Plugs.Locale do
  @moduledoc "Negotiates the request/LiveView locale (en/pt) and applies it to Gettext."
  import Plug.Conn

  @supported ~w(en pt)
  @default Application.compile_env(
             :ravanshenasi,
             [RavanshenasiWeb.Gettext, :default_locale],
             "en"
           )

  # --- Plug (HTTP requests) ---
  def init(opts), do: opts

  def call(conn, _opts) do
    locale =
      locale_from_params(conn) ||
        get_session(conn, :locale) ||
        locale_from_header(conn) ||
        @default

    Gettext.put_locale(RavanshenasiWeb.Gettext, locale)
    put_session(conn, :locale, locale)
  end

  # --- on_mount (LiveView) ---
  def on_mount(:set_locale, _params, session, socket) do
    Gettext.put_locale(RavanshenasiWeb.Gettext, session["locale"] || @default)
    {:cont, socket}
  end

  defp locale_from_params(conn) do
    case conn.params do
      %{"locale" => loc} when loc in @supported -> loc
      _ -> nil
    end
  end

  defp locale_from_header(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
    |> parse_accept_language()
  end

  defp parse_accept_language(nil), do: nil

  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.map(fn part ->
      part |> String.split(";") |> hd() |> String.trim() |> String.slice(0, 2)
    end)
    |> Enum.find(&(&1 in @supported))
  end
end
