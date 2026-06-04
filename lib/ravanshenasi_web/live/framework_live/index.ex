defmodule RavanshenasiWeb.FrameworkLive.Index do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Frameworks

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(form: empty_form(), editing: nil, edit_form: nil) |> load()}
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

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    fw = Frameworks.get_framework!(scope, id)
    edit_form = to_form(Frameworks.change_framework(fw), as: :framework)
    {:noreply, assign(socket, editing: id, edit_form: edit_form)}
  end

  @impl true
  def handle_event("cancel-edit", _, socket) do
    {:noreply, assign(socket, editing: nil, edit_form: nil)}
  end

  @impl true
  def handle_event("update", %{"framework" => params}, socket) do
    scope = socket.assigns.current_scope
    fw = Frameworks.get_framework!(scope, socket.assigns.editing)

    case Frameworks.update_framework(scope, fw, params) do
      {:ok, _} ->
        {:noreply, socket |> assign(editing: nil, edit_form: nil) |> load()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized"))}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, edit_form: to_form(cs, as: :framework))}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    fw = Frameworks.get_framework!(scope, id)

    case Frameworks.delete_framework(scope, fw) do
      {:ok, _} -> {:noreply, socket |> load()}
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
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
        <li :for={f <- @frameworks}>
          {f.name}{if f.is_predefined, do: " ⭐"}
          <span :if={Frameworks.can_manage?(@current_scope, f)}>
            <.button phx-click="edit" phx-value-id={f.id}>{gettext("Edit")}</.button>
            <.button
              phx-click="delete"
              phx-value-id={f.id}
              data-confirm={gettext("Delete this line?")}
            >
              {gettext("Delete")}
            </.button>
          </span>
          <div :if={@editing == f.id} id={"framework-edit-form-#{f.id}"}>
            <.form for={@edit_form} phx-submit="update">
              <.input
                field={@edit_form[:name]}
                id={"edit_framework_name_#{f.id}"}
                label={gettext("Name")}
                required
              />
              <.input
                field={@edit_form[:description]}
                id={"edit_framework_description_#{f.id}"}
                type="textarea"
                label={gettext("Guiding principles")}
              />
              <.button type="submit">{gettext("Save")}</.button>
              <.button type="button" phx-click="cancel-edit">{gettext("Cancel")}</.button>
            </.form>
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
