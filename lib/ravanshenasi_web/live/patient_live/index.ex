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
          <li :for={p <- @patients} class="flex items-center justify-between gap-3 py-3">
            <.link
              navigate={~p"/pacientes/#{p.id}"}
              class="font-medium hover:text-primary"
            >
              {p.name}
            </.link>
            <.badge variant={patient_status_variant(p.status)}>{p.status}</.badge>
          </li>
        </ul>
      </.card>
    </Layouts.app>
    """
  end

  defp patient_status_variant(:active), do: "success"
  defp patient_status_variant(:inactive), do: "secondary"
  defp patient_status_variant(:waitlist), do: "warning"
  defp patient_status_variant(_), do: "outline"
end
