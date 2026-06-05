defmodule RavanshenasiWeb.PatientLive.Show do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Analyses
  alias Ravanshenasi.Frameworks
  alias Ravanshenasi.Patients

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Patients.get_patient(scope, id) do
      nil ->
        {:ok,
         socket
         |> Phoenix.LiveView.put_flash(:error, gettext("Patient not found"))
         |> Phoenix.LiveView.push_navigate(to: ~p"/pacientes")}

      patient ->
        {:ok,
         socket
         |> assign(patient: patient, no_frameworks_warning: false)
         |> load_frameworks()
         |> load_analysis()}
    end
  end

  @impl true
  def handle_event("inactivate", _, socket) do
    scope = socket.assigns.current_scope

    case Patients.inactivate_patient(scope, socket.assigns.patient) do
      {:ok, patient} ->
        {:noreply,
         socket |> assign(patient: patient) |> put_flash(:info, gettext("Patient inactivated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not inactivate patient"))}
    end
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

  @impl true
  def handle_event("analyze", _, socket) do
    scope = socket.assigns.current_scope

    case Analyses.analyze_patient(scope, socket.assigns.patient) do
      {:ok, analysis} ->
        Analyses.subscribe(analysis.id)

        {:noreply,
         assign(socket,
           analysis: analysis,
           suggestions: load_suggestions(scope, analysis),
           no_frameworks_warning: false
         )}

      {:error, :no_active_frameworks} ->
        {:noreply, assign(socket, analysis: nil, suggestions: [], no_frameworks_warning: true)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not allowed"))}

      # A rare partial-index race may return {:error, changeset}; keep the UI stable.
      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not start the analysis"))}
    end
  end

  @impl true
  def handle_event("save-suggestion", %{"id" => id}, socket) do
    case Analyses.save_suggestion(socket.assigns.current_scope, %{id: id}) do
      {:ok, _} -> {:noreply, reload_suggestions(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not update suggestion"))}
    end
  end

  @impl true
  def handle_event("discard-suggestion", %{"id" => id}, socket) do
    case Analyses.discard_suggestion(socket.assigns.current_scope, %{id: id}) do
      {:ok, _} -> {:noreply, reload_suggestions(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not update suggestion"))}
    end
  end

  @impl true
  def handle_info({:analysis_updated, analysis}, socket) do
    scope = socket.assigns.current_scope
    {:noreply, assign(socket, analysis: analysis, suggestions: load_suggestions(scope, analysis))}
  end

  defp load_frameworks(socket) do
    scope = socket.assigns.current_scope
    all = Frameworks.list_frameworks(scope)

    active_ids =
      Patients.list_patient_frameworks(scope, socket.assigns.patient)
      |> MapSet.new(& &1.id)

    assign(socket, all_frameworks: all, active_ids: active_ids)
  end

  defp load_analysis(socket) do
    scope = socket.assigns.current_scope
    analysis = Analyses.list_analyses(scope, %{id: socket.assigns.patient.id}) |> List.first()

    if analysis && analysis.generation_status in [:pending, :generating],
      do: Analyses.subscribe(analysis.id)

    assign(socket, analysis: analysis, suggestions: load_suggestions(scope, analysis))
  end

  defp reload_suggestions(socket) do
    scope = socket.assigns.current_scope
    assign(socket, suggestions: load_suggestions(scope, socket.assigns.analysis))
  end

  defp load_suggestions(scope, %{generation_status: :done} = analysis),
    do: Analyses.list_suggestions(scope, %{id: analysis.id})

  defp load_suggestions(_scope, _analysis), do: []

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

      <section id="analysis-section">
        <h3>{gettext("Approach suggestions")}</h3>
        <.button id="analyze-patient-button" phx-click="analyze">
          {gettext("Analyze patient")}
        </.button>

        <p :if={@no_frameworks_warning} id="no-frameworks-warning">
          {gettext("Configure lines of thought for this patient before analyzing.")}
        </p>

        <p
          :if={@analysis && @analysis.generation_status in [:pending, :generating]}
          id="analysis-generating"
        >
          {gettext("Analyzing…")}
        </p>

        <div :if={@analysis && @analysis.generation_status == :error} id="analysis-error">
          <p>{gettext("Analysis failed.")}</p>
          <.button id="retry-analysis-button" phx-click="analyze">
            {gettext("Try again")}
          </.button>
        </div>

        <div :if={@analysis && @analysis.generation_status == :done} id="suggestions">
          <div :for={s <- @suggestions} id={"suggestion-#{s.id}"} class="card">
            <h4>{s.framework_name}</h4>
            <p>{s.justification}</p>
            <ul>
              <li :for={t <- s.techniques}>{t}</li>
            </ul>
            <p>{s.watch_out}</p>
            <span id={"suggestion-status-#{s.id}"}>{s.status}</span>
            <.button id={"save-suggestion-#{s.id}"} phx-click="save-suggestion" phx-value-id={s.id}>
              {gettext("Save")}
            </.button>
            <.button
              id={"discard-suggestion-#{s.id}"}
              phx-click="discard-suggestion"
              phx-value-id={s.id}
            >
              {gettext("Discard")}
            </.button>
          </div>
        </div>
      </section>

      <.button navigate={~p"/pacientes/#{@patient.id}/editar"}>{gettext("Edit")}</.button>
      <.button
        :if={@patient.status != :inactive}
        phx-click="inactivate"
        data-confirm={gettext("Inactivate this patient?")}
      >
        {gettext("Inactivate patient")}
      </.button>
    </Layouts.app>
    """
  end
end
