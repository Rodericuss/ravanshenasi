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
        <:subtitle>{gettext("All sessions for this patient")}</:subtitle>
        <:actions>
          <.button navigate={~p"/pacientes/#{@patient.id}/sessoes/nova"}>
            <.icon name="hero-plus" class="size-4" />
            {gettext("New session")}
          </.button>
        </:actions>
      </.header>

      <.card>
        <:title>{gettext("Sessions")}</:title>
        <.empty_state :if={@sessions == []} title={gettext("No sessions yet.")}>
          {gettext("Create the first session for this patient.")}
        </.empty_state>
        <ul :if={@sessions != []} id="sessions" class="-my-1 divide-y divide-border">
          <li :for={s <- @sessions}>
            <.link
              navigate={~p"/pacientes/#{@patient.id}/sessoes/#{s.id}"}
              class="-mx-2 flex items-center justify-between gap-3 rounded-md px-2 py-2 transition hover:bg-muted/50"
            >
              <span class="font-medium">{session_date(s.date)}</span>
              <.status_badge value={s.status} />
            </.link>
          </li>
        </ul>
      </.card>
    </Layouts.app>
    """
  end

  defp session_date(nil), do: "—"
  defp session_date(%DateTime{} = d), do: Calendar.strftime(d, "%d/%m/%Y")
  defp session_date(%Date{} = d), do: Calendar.strftime(d, "%d/%m/%Y")
  defp session_date(d), do: to_string(d)
end
