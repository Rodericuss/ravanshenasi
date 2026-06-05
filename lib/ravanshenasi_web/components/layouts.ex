defmodule RavanshenasiWeb.Layouts do
  @moduledoc """
  App layouts: a sidebar shell for authenticated screens (`app/1`) and a
  centered card for auth screens (`auth/1`). Styling uses the Metronic-inspired
  design tokens defined in `assets/css/app.css`.
  """
  use RavanshenasiWeb, :html

  alias Ravanshenasi.Accounts.Scope

  embed_templates "layouts/*"

  @nav [
    %{label: "Dashboard", path: "/painel", icon: "hero-squares-2x2", guard: :clinical},
    %{label: "Patients", path: "/pacientes", icon: "hero-users", guard: :clinical},
    %{
      label: "Lines of thought",
      path: "/linhas",
      icon: "hero-light-bulb",
      guard: :clinical_or_admin
    },
    %{label: "Team", path: "/equipe", icon: "hero-user-group", guard: :clinic_admin}
  ]

  @doc """
  The application shell: fixed sidebar + topbar. Used by authenticated screens.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav, visible_nav(assigns.current_scope))

    ~H"""
    <div class="min-h-screen bg-background text-foreground">
      <aside
        id="sidebar"
        class="fixed inset-y-0 left-0 z-40 flex w-64 -translate-x-full flex-col border-r border-sidebar-border bg-sidebar text-sidebar-foreground transition-transform duration-200 lg:translate-x-0"
      >
        <div class="flex h-16 items-center gap-2 border-b border-sidebar-border px-5">
          <img src={~p"/images/logo.svg"} width="28" alt="PsiCare" />
          <span class="text-base font-semibold text-foreground">PsiCare</span>
        </div>
        <nav class="flex-1 space-y-1 overflow-y-auto p-3">
          <.link
            :for={item <- @nav}
            navigate={item.path}
            data-active-nav="true"
            class="flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium text-sidebar-foreground transition-colors hover:bg-accent hover:text-accent-foreground"
          >
            <.icon name={item.icon} class="size-5 shrink-0 opacity-70" />
            {Gettext.gettext(RavanshenasiWeb.Gettext, item.label)}
          </.link>
        </nav>
        <div :if={@current_scope} class="border-t border-sidebar-border p-3">
          <div class="truncate px-3 py-1 text-xs text-muted-foreground">
            {@current_scope.user.email}
          </div>
          <.link
            navigate={~p"/users/settings"}
            class="flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium hover:bg-accent hover:text-accent-foreground"
          >
            <.icon name="hero-cog-6-tooth" class="size-5 shrink-0 opacity-70" />
            {gettext("Settings")}
          </.link>
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium hover:bg-accent hover:text-accent-foreground"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-5 shrink-0 opacity-70" />
            {gettext("Log out")}
          </.link>
        </div>
      </aside>

      <div
        id="sidebar-overlay"
        class="fixed inset-0 z-30 hidden bg-black/40 lg:hidden"
        phx-click={toggle_sidebar()}
      >
      </div>

      <div class="flex min-h-screen flex-col lg:pl-64">
        <header class="sticky top-0 z-20 flex h-16 items-center gap-3 border-b border-border bg-background/80 px-4 backdrop-blur sm:px-6">
          <button
            type="button"
            class="rounded-md p-2 hover:bg-accent lg:hidden"
            phx-click={toggle_sidebar()}
            aria-label={gettext("Toggle menu")}
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
          <div class="flex-1"></div>
          <.theme_toggle />
        </header>

        <main class="flex-1 p-4 sm:p-6 lg:p-8">
          <div class="mx-auto w-full max-w-7xl">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Centered card layout for unauthenticated screens (login, register, invite).

  ## Examples

      <Layouts.auth flash={@flash}>
        <.form ...>
      </Layouts.auth>
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col items-center justify-center bg-muted/30 p-4 text-foreground">
      <div class="mb-6 flex items-center gap-2">
        <img src={~p"/images/logo.svg"} width="32" alt="PsiCare" />
        <span class="text-lg font-semibold">PsiCare</span>
      </div>
      <main class="w-full max-w-md rounded-lg border bg-card p-6 text-card-foreground shadow-sm sm:p-8">
        {render_slot(@inner_block)}
      </main>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp visible_nav(scope) do
    Enum.filter(@nav, fn item ->
      case item.guard do
        :clinical -> Scope.clinical_access?(scope)
        :clinical_or_admin -> Scope.clinical_access?(scope) or Scope.admin?(scope)
        :clinic_admin -> Scope.clinic_admin?(scope)
      end
    end)
  end

  # Toggles the mobile sidebar (off-canvas) and its overlay.
  defp toggle_sidebar do
    JS.toggle_class("-translate-x-full", to: "#sidebar")
    |> JS.toggle(to: "#sidebar-overlay")
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Light / dark / system theme toggle. Applied before paint in root.html.heex.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex items-center rounded-full border border-border bg-muted p-0.5">
      <button
        class="flex cursor-pointer rounded-full p-1.5 hover:bg-accent"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      <button
        class="flex cursor-pointer rounded-full p-1.5 hover:bg-accent"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      <button
        class="flex cursor-pointer rounded-full p-1.5 hover:bg-accent"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
