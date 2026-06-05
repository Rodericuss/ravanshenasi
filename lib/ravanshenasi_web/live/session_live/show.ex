defmodule RavanshenasiWeb.SessionLive.Show do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.{Patients, Records, Sessions}

  @impl true
  def mount(%{"patient_id" => pid, "id" => sid}, _session, socket) do
    scope = socket.assigns.current_scope
    patient = Patients.get_patient!(scope, pid)

    case Sessions.get_session_for_patient(scope, patient, sid) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Session not found"))
         |> push_navigate(to: ~p"/pacientes/#{pid}/sessoes")}

      session ->
        record = Records.get_record_for_session(scope, session)
        if connected?(socket) and record, do: Records.subscribe(record.id)
        {:ok, assign(socket, patient: patient, session: session, record: record)}
    end
  end

  @impl true
  def handle_event("finalize", _, socket) do
    case Sessions.finalize_session(socket.assigns.current_scope, socket.assigns.session) do
      {:ok, %{session: sess, record: rec}} ->
        if connected?(socket), do: Records.subscribe(rec.id)
        {:noreply, assign(socket, session: sess, record: rec)}

      {:error, :already_finalized} ->
        {:noreply, put_flash(socket, :error, gettext("Already finalized"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not finalize"))}
    end
  end

  def handle_event("retry", _, socket) do
    case Records.retry_generation(socket.assigns.current_scope, socket.assigns.record) do
      {:ok, rec} -> {:noreply, assign(socket, record: rec)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not retry generation"))}
    end
  end

  @impl true
  def handle_info({:record_updated, rec}, socket), do: {:noreply, assign(socket, record: rec)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {gettext("Session")} — {@patient.name}
        <:subtitle>{session_date(@session.date)}</:subtitle>
        <:actions>
          <.status_badge value={@session.status} />
          <.button
            :if={@session.status == :draft}
            id="finalize-session-button"
            phx-click="finalize"
          >
            <.icon name="hero-check" class="size-4" />
            {gettext("Finalize")}
          </.button>
        </:actions>
      </.header>

      <div class="grid gap-4 lg:grid-cols-2">
        <.card>
          <:title>{gettext("Notes")}</:title>
          <p class="text-sm text-muted-foreground whitespace-pre-wrap">
            {if @session.notes && @session.notes != "", do: @session.notes, else: gettext("No notes.")}
          </p>
        </.card>

        <.card :if={@record}>
          <:title>{gettext("SOAP Record")}</:title>

          <div
            :if={@record.generation_status in [:pending, :generating]}
            id="record-generating"
            class="flex items-center gap-2 text-sm text-muted-foreground"
          >
            <.icon name="hero-arrow-path" class="size-4 animate-spin" />
            {gettext("Generating record...")}
          </div>

          <div :if={@record.generation_status == :done}>
            <pre
              id="soap-record-content"
              class="whitespace-pre-wrap text-sm font-mono bg-muted rounded-md p-3 overflow-auto"
            >{@record.content}</pre>
          </div>

          <div :if={@record.generation_status == :error} id="record-error">
            <div class="flex items-start gap-2 rounded-md bg-destructive/10 p-3 text-sm text-destructive">
              <.icon name="hero-exclamation-circle" class="size-4 mt-0.5 shrink-0" />
              <span>{gettext("Generation failed")}: {@record.error_reason}</span>
            </div>
            <div class="mt-3 flex justify-end">
              <.button
                id="retry-generation-button"
                variant="outline"
                phx-click="retry"
              >
                <.icon name="hero-arrow-path" class="size-4" />
                {gettext("Try again")}
              </.button>
            </div>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp session_date(nil), do: "—"
  defp session_date(%DateTime{} = d), do: Calendar.strftime(d, "%d/%m/%Y")
  defp session_date(%Date{} = d), do: Calendar.strftime(d, "%d/%m/%Y")
  defp session_date(d), do: to_string(d)
end
