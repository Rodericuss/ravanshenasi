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

      <form id="patient-search" phx-change="search">
        <.input type="text" name="q" value={@q} placeholder={gettext("Search by name")} />
      </form>

      <form id="patient-filter" phx-change="filter">
        <select name="status">
          <option value="">{gettext("All")}</option>
          <option value="active" selected={@status == :active}>{gettext("Active")}</option>
          <option value="inactive" selected={@status == :inactive}>{gettext("Inactive")}</option>
          <option value="waitlist" selected={@status == :waitlist}>{gettext("Waitlist")}</option>
        </select>
      </form>

      <ul id="patients">
        <li :for={p <- @patients}>
          <.link navigate={~p"/pacientes/#{p.id}"}>{p.name}</.link> — {p.status}
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
