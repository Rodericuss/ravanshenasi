defmodule RavanshenasiWeb.DashboardLive.Index do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.{AudioMessages, Patients, Records, Sessions}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       pending_review: Records.list_pending_review(scope),
       pending_review_count: Records.count_pending_review(scope),
       recent_audios: AudioMessages.list_recent(scope),
       recent_sessions: Sessions.list_recent(scope),
       active_count: Patients.count_active(scope),
       recent_patients: Patients.list_recent(scope)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>{gettext("Dashboard")}</.header>

      <section id="card-pending-review">
        <h3>{gettext("Records pending review")} ({@pending_review_count})</h3>
        <p :if={@pending_review == []}>{gettext("No records pending review.")}</p>
        <ul>
          <li :for={r <- @pending_review} id={"pending-review-#{r.id}"}>
            <.link navigate={~p"/pacientes/#{r.patient_id}/sessoes/#{r.session_id}"}>
              {r.patient.name} — {Calendar.strftime(r.inserted_at, "%d/%m/%Y")}
            </.link>
          </li>
        </ul>
      </section>

      <section id="card-recent-audios">
        <h3>{gettext("Recent audios")}</h3>
        <p :if={@recent_audios == []}>{gettext("No recent audios.")}</p>
        <ul>
          <li :for={a <- @recent_audios} id={"recent-audio-#{a.id}"}>
            <.link navigate={~p"/pacientes/#{a.patient_id}/audios"}>
              {a.patient.name} — {a.original_filename} ({a.status})
            </.link>
          </li>
        </ul>
      </section>

      <section id="card-recent-sessions">
        <h3>{gettext("Recent sessions")}</h3>
        <p :if={@recent_sessions == []}>{gettext("No recent sessions.")}</p>
        <ul>
          <li :for={se <- @recent_sessions} id={"recent-session-#{se.id}"}>
            <.link navigate={~p"/pacientes/#{se.patient_id}/sessoes/#{se.id}"}>
              {se.patient.name} — {session_date(se.date)} ({se.status})
            </.link>
          </li>
        </ul>
      </section>

      <section id="card-active-patients">
        <h3>{gettext("Active patients")} ({@active_count})</h3>
        <p :if={@recent_patients == []}>{gettext("No active patients.")}</p>
        <ul>
          <li :for={p <- @recent_patients} id={"active-patient-#{p.id}"}>
            <.link navigate={~p"/pacientes/#{p.id}"}>{p.name} ({p.status})</.link>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  defp session_date(nil), do: "—"
  defp session_date(%DateTime{} = d), do: Calendar.strftime(d, "%d/%m/%Y")
end
