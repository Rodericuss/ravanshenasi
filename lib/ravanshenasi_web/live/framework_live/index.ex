defmodule RavanshenasiWeb.FrameworkLive.Index do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Frameworks
  alias Ravanshenasi.Accounts.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(form: empty_form()) |> load()}
  end

  @impl true
  def handle_event("create", %{"framework" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      if Scope.admin?(scope) and not Scope.clinical_access?(scope) do
        # clinic admin manages the tenant catalog
        Frameworks.create_tenant_framework(scope, params)
      else
        Frameworks.create_own_framework(scope, params)
      end

    case result do
      {:ok, _} -> {:noreply, socket |> assign(form: empty_form()) |> load()}
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
      {:error, %Ecto.Changeset{} = cs} -> {:noreply, assign(socket, form: to_form(cs))}
    end
  end

  defp empty_form, do: to_form(%{"name" => "", "description" => ""}, as: :framework)

  defp load(socket) do
    assign(socket, frameworks: Frameworks.list_frameworks(socket.assigns.current_scope))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>{gettext("Lines of thought")}</.header>
      <.form for={@form} id="framework-form" phx-submit="create">
        <.input field={@form[:name]} label={gettext("Name")} required />
        <.input field={@form[:description]} type="textarea" label={gettext("Guiding principles")} />
        <.button>{gettext("Add line")}</.button>
      </.form>
      <ul id="frameworks">
        <li :for={f <- @frameworks}>{f.name}{if f.is_predefined, do: " ⭐"}</li>
      </ul>
    </Layouts.app>
    """
  end
end
