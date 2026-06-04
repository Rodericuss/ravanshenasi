defmodule RavanshenasiWeb.SessionLive.Index do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.{Patients, Sessions}

  @impl true
  def mount(%{"patient_id" => pid}, _session, socket) do
    scope = socket.assigns.current_scope
    patient = Patients.get_patient!(scope, pid)
    sessions = Sessions.list_sessions(scope, patient)
    {:ok, assign(socket, patient: patient, sessions: sessions)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {gettext("Sessions")} — {@patient.name}
        <:actions>
          <.button navigate={~p"/pacientes/#{@patient.id}/sessoes/nova"}>
            {gettext("New session")}
          </.button>
        </:actions>
      </.header>

      <ul id="sessions">
        <li :for={s <- @sessions}>
          <.link navigate={~p"/pacientes/#{@patient.id}/sessoes/#{s.id}"}>
            {s.date} — {s.status}
          </.link>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
