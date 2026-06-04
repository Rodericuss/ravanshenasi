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
      <.header>{gettext("Session")} — {@patient.name}</.header>
      <p>{@session.notes}</p>
      <.button :if={@session.status == :draft} id="finalize-session-button" phx-click="finalize">
        {gettext("Finalize")}
      </.button>

      <div :if={@record}>
        <p :if={@record.generation_status in [:pending, :generating]} id="record-generating">
          {gettext("Generating record...")}
        </p>
        <div :if={@record.generation_status == :done}>
          <h3>{gettext("SOAP record")}</h3>
          <pre id="soap-record-content">{@record.content}</pre>
        </div>
        <div :if={@record.generation_status == :error} id="record-error">
          <p>{gettext("Generation failed")}: {@record.error_reason}</p>
          <.button id="retry-generation-button" phx-click="retry">{gettext("Try again")}</.button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
