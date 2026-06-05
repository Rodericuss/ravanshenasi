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
      <.header>
        {gettext("Dashboard")}
        <:subtitle>{gettext("Overview of your clinical work")}</:subtitle>
      </.header>

      <div class="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.stat_card label={gettext("Active patients")} value={@active_count} icon="hero-users" />
        <.stat_card
          label={gettext("Pending review")}
          value={@pending_review_count}
          icon="hero-document-text"
        />
        <.stat_card
          label={gettext("Recent audios")}
          value={length(@recent_audios)}
          icon="hero-microphone"
        />
        <.stat_card
          label={gettext("Recent sessions")}
          value={length(@recent_sessions)}
          icon="hero-calendar-days"
        />
      </div>

      <div class="grid gap-4 lg:grid-cols-2">
        <.card id="card-pending-review">
          <:title>{gettext("Records pending review")} ({@pending_review_count})</:title>
          <.empty_state :if={@pending_review == []} title={gettext("No records pending review.")} />
          <ul :if={@pending_review != []} class="-my-1 divide-y divide-border">
            <li :for={r <- @pending_review} id={"pending-review-#{r.id}"}>
              <.link
                navigate={~p"/pacientes/#{r.patient_id}/sessoes/#{r.session_id}"}
                class="flex items-center justify-between gap-3 py-2.5 hover:text-primary"
              >
                <span class="font-medium">{r.patient.name}</span>
                <span class="text-sm text-muted-foreground">
                  {Calendar.strftime(r.inserted_at, "%d/%m/%Y")}
                </span>
              </.link>
            </li>
          </ul>
        </.card>

        <.card id="card-recent-audios">
          <:title>{gettext("Recent audios")}</:title>
          <.empty_state :if={@recent_audios == []} title={gettext("No recent audios.")} />
          <ul :if={@recent_audios != []} class="-my-1 divide-y divide-border">
            <li :for={a <- @recent_audios} id={"recent-audio-#{a.id}"}>
              <.link
                navigate={~p"/pacientes/#{a.patient_id}/audios"}
                class="flex items-center justify-between gap-3 py-2.5 hover:text-primary"
              >
                <span class="min-w-0 truncate">
                  <span class="font-medium">{a.patient.name}</span>
                  <span class="text-muted-foreground">— {a.original_filename}</span>
                </span>
                <.badge variant={audio_variant(a.status)}>{a.status}</.badge>
              </.link>
            </li>
          </ul>
        </.card>

        <.card id="card-recent-sessions">
          <:title>{gettext("Recent sessions")}</:title>
          <.empty_state :if={@recent_sessions == []} title={gettext("No recent sessions.")} />
          <ul :if={@recent_sessions != []} class="-my-1 divide-y divide-border">
            <li :for={se <- @recent_sessions} id={"recent-session-#{se.id}"}>
              <.link
                navigate={~p"/pacientes/#{se.patient_id}/sessoes/#{se.id}"}
                class="flex items-center justify-between gap-3 py-2.5 hover:text-primary"
              >
                <span class="font-medium">{se.patient.name}</span>
                <span class="text-sm text-muted-foreground">
                  {session_date(se.date)} · {se.status}
                </span>
              </.link>
            </li>
          </ul>
        </.card>

        <.card id="card-active-patients">
          <:title>{gettext("Active patients")} ({@active_count})</:title>
          <.empty_state :if={@recent_patients == []} title={gettext("No active patients.")} />
          <ul :if={@recent_patients != []} class="-my-1 divide-y divide-border">
            <li :for={p <- @recent_patients} id={"active-patient-#{p.id}"}>
              <.link
                navigate={~p"/pacientes/#{p.id}"}
                class="flex items-center justify-between gap-3 py-2.5 hover:text-primary"
              >
                <span class="font-medium">{p.name}</span>
                <.badge variant="outline">{p.status}</.badge>
              </.link>
            </li>
          </ul>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp session_date(nil), do: "—"
  defp session_date(%DateTime{} = d), do: Calendar.strftime(d, "%d/%m/%Y")

  defp audio_variant(:done), do: "success"
  defp audio_variant(:error), do: "destructive"
  defp audio_variant(_), do: "secondary"
end
