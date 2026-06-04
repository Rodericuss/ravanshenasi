defmodule RavanshenasiWeb.PatientLive.Show do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.{Patients, Frameworks}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    patient = Patients.get_patient!(scope, id)
    {:ok, socket |> assign(patient: patient) |> load_frameworks()}
  end

  @impl true
  def handle_event("toggle-framework", %{"id" => fw_id, "on" => on}, socket) do
    scope = socket.assigns.current_scope
    framework = Frameworks.get_framework!(scope, fw_id)

    if on == "true" do
      Patients.activate_framework(scope, socket.assigns.patient, framework)
    else
      Patients.deactivate_framework(scope, socket.assigns.patient, framework)
    end

    {:noreply, load_frameworks(socket)}
  end

  defp load_frameworks(socket) do
    scope = socket.assigns.current_scope
    all = Frameworks.list_frameworks(scope)

    active_ids =
      Patients.list_patient_frameworks(scope, socket.assigns.patient)
      |> MapSet.new(& &1.id)

    assign(socket, all_frameworks: all, active_ids: active_ids)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>{@patient.name}</.header>
      <p>{@patient.chief_complaint}</p>

      <h3>{gettext("Lines of thought")}</h3>
      <ul>
        <li :for={f <- @all_frameworks}>
          <label>
            <input
              type="checkbox"
              checked={MapSet.member?(@active_ids, f.id)}
              phx-click="toggle-framework"
              phx-value-id={f.id}
              phx-value-on={to_string(not MapSet.member?(@active_ids, f.id))}
            />
            {f.name}
          </label>
        </li>
      </ul>
      <.button navigate={~p"/pacientes/#{@patient.id}/editar"}>{gettext("Edit")}</.button>
    </Layouts.app>
    """
  end
end
