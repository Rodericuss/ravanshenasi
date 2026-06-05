defmodule RavanshenasiWeb.PatientLive.Index do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Patients

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, q: "", status: nil) |> load()}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(q: q) |> load()}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    parsed =
      case status do
        "" -> nil
        s -> String.to_existing_atom(s)
      end

    {:noreply, socket |> assign(status: parsed) |> load()}
  end

  defp load(socket) do
    patients =
      Patients.list_patients(socket.assigns.current_scope,
        q: socket.assigns.q,
        status: socket.assigns.status
      )

    assign(socket, patients: patients)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {gettext("Patients")}
        <:actions>
          <.button navigate={~p"/pacientes/novo"}>{gettext("New patient")}</.button>
        </:actions>
      </.header>

      <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center">
        <form id="patient-search" phx-change="search" class="flex-1">
          <.input type="text" name="q" value={@q} placeholder={gettext("Search by name")} />
        </form>

        <form id="patient-filter" phx-change="filter">
          <select
            name="status"
            class="rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-primary"
          >
            <option value="">{gettext("All")}</option>
            <option value="active" selected={@status == :active}>{gettext("Active")}</option>
            <option value="inactive" selected={@status == :inactive}>{gettext("Inactive")}</option>
            <option value="waitlist" selected={@status == :waitlist}>{gettext("Waitlist")}</option>
          </select>
        </form>
      </div>

      <.card>
        <.empty_state :if={@patients == []} icon="hero-users" title={gettext("No patients found.")} />
        <ul :if={@patients != []} id="patients" class="-my-1 divide-y divide-border">
          <li :for={p <- @patients}>
            <.link
              navigate={~p"/pacientes/#{p.id}"}
              class="-mx-2 flex items-center gap-3 rounded-md px-2 py-2 transition hover:bg-muted/50"
            >
              <.avatar name={p.name} class="size-8" />
              <span class="flex-1 font-medium">{p.name}</span>
              <.status_badge value={p.status} />
            </.link>
          </li>
        </ul>
      </.card>
    </Layouts.app>
    """
  end
end
