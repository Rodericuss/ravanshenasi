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
      <.header>
        {gettext("Lines of thought")}
        <:subtitle>
          {gettext("Frameworks and therapeutic approaches used in your practice")}
        </:subtitle>
        <:actions></:actions>
      </.header>

      <div class="grid gap-6 lg:grid-cols-3 mt-6">
        <div class="lg:col-span-1">
          <.card>
            <:title>{gettext("Add new line")}</:title>
            <.form for={@form} id="framework-form" phx-submit="create" class="space-y-4">
              <.input field={@form[:name]} label={gettext("Name")} required />
              <.input
                field={@form[:description]}
                type="textarea"
                label={gettext("Guiding principles")}
              />
              <.button class="w-full">{gettext("Add line")}</.button>
            </.form>
          </.card>
        </div>

        <div class="lg:col-span-2">
          <.card>
            <:title>{gettext("Your lines")}</:title>
            <.empty_state
              :if={@frameworks == []}
              icon="hero-academic-cap"
              title={gettext("No lines yet")}
            >
              {gettext("Add a therapeutic framework to get started.")}
            </.empty_state>
            <ul id="frameworks" class="divide-y divide-border">
              <li :for={f <- @frameworks} class="py-4">
                <div class="flex items-center justify-between gap-4">
                  <div class="flex items-center gap-2">
                    <span class="font-medium text-foreground">{f.name}</span>
                    <.badge :if={f.is_predefined} variant="info">{gettext("Standard")}</.badge>
                  </div>
                  <span
                    :if={Frameworks.can_manage?(@current_scope, f)}
                    class="flex items-center gap-2"
                  >
                    <.button variant="ghost" phx-click="edit" phx-value-id={f.id}>
                      {gettext("Edit")}
                    </.button>
                    <.button
                      variant="destructive"
                      phx-click="delete"
                      phx-value-id={f.id}
                      data-confirm={gettext("Delete this line?")}
                    >
                      {gettext("Delete")}
                    </.button>
                  </span>
                </div>
                <div
                  :if={@editing == f.id}
                  id={"framework-edit-form-#{f.id}"}
                  class="mt-4 rounded-lg border border-border bg-muted/40 p-4"
                >
                  <.form for={@edit_form} phx-submit="update" class="space-y-4">
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
                    <div class="flex gap-2">
                      <.button type="submit">{gettext("Save")}</.button>
                      <.button type="button" variant="outline" phx-click="cancel-edit">
                        {gettext("Cancel")}
                      </.button>
                    </div>
                  </.form>
                </div>
              </li>
            </ul>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
