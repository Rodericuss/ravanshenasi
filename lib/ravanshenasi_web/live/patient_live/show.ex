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
      <.header>
        <span class="flex items-center gap-3">
          <.avatar name={@patient.name} class="size-10" />
          <span class="flex items-center gap-2">
            {@patient.name}
            <.status_badge value={@patient.status} />
          </span>
        </span>
        <:subtitle :if={@patient.chief_complaint}>{@patient.chief_complaint}</:subtitle>
        <:actions>
          <.button variant="outline" navigate={~p"/pacientes/#{@patient.id}/editar"}>
            {gettext("Edit")}
          </.button>
          <.button
            :if={@patient.status != :inactive}
            variant="destructive"
            phx-click="inactivate"
            data-confirm={gettext("Inactivate this patient?")}
          >
            {gettext("Inactivate patient")}
          </.button>
        </:actions>
      </.header>

      <div class="grid gap-4 lg:grid-cols-3">
        <%!-- Lines of thought card --%>
        <.card class="lg:col-span-1">
          <:title>{gettext("Lines of thought")}</:title>
          <.empty_state
            :if={@all_frameworks == []}
            icon="hero-square-3-stack-3d"
            title={gettext("No lines configured.")}
          />
          <ul :if={@all_frameworks != []} class="space-y-2">
            <li :for={f <- @all_frameworks} class="flex items-center gap-3">
              <label class="flex cursor-pointer items-center gap-2">
                <input
                  type="checkbox"
                  checked={MapSet.member?(@active_ids, f.id)}
                  phx-click="toggle-framework"
                  phx-value-id={f.id}
                  phx-value-on={to_string(not MapSet.member?(@active_ids, f.id))}
                  class="size-4 rounded border-border text-primary accent-primary"
                />
                <span class="text-sm font-medium">{f.name}</span>
              </label>
            </li>
          </ul>
        </.card>

        <%!-- Analysis section --%>
        <section id="analysis-section" class="lg:col-span-2">
          <.card>
            <:title>{gettext("Approach suggestions")}</:title>
            <:actions>
              <.button id="analyze-patient-button" phx-click="analyze">
                {gettext("Analyze patient")}
              </.button>
            </:actions>

            <p
              :if={@no_frameworks_warning}
              id="no-frameworks-warning"
              class="text-sm text-muted-foreground"
            >
              {gettext("Configure lines of thought for this patient before analyzing.")}
            </p>

            <div
              :if={@analysis && @analysis.generation_status in [:pending, :generating]}
              id="analysis-generating"
              class="flex items-center gap-2 text-sm text-muted-foreground"
            >
              <.icon name="hero-arrow-path" class="size-4 animate-spin" />
              {gettext("Analyzing…")}
            </div>

            <div
              :if={@analysis && @analysis.generation_status == :error}
              id="analysis-error"
              class="rounded-md bg-destructive/10 p-4 text-destructive"
            >
              <p class="text-sm font-medium">{gettext("Analysis failed.")}</p>
              <.button id="retry-analysis-button" variant="outline" phx-click="analyze" class="mt-2">
                {gettext("Try again")}
              </.button>
            </div>

            <div
              :if={@analysis && @analysis.generation_status == :done}
              id="suggestions"
              class="space-y-4"
            >
              <div
                :for={s <- @suggestions}
                id={"suggestion-#{s.id}"}
                class="rounded-lg border border-border bg-muted/40 p-4"
              >
                <div class="mb-2 flex items-center justify-between gap-2">
                  <h4 class="font-semibold">{s.framework_name}</h4>
                  <span id={"suggestion-status-#{s.id}"}>
                    <.status_badge value={s.status} />
                  </span>
                </div>
                <p class="mb-2 text-sm text-muted-foreground">{s.justification}</p>
                <ul :if={s.techniques != []} class="mb-2 ml-4 list-disc space-y-1 text-sm">
                  <li :for={t <- s.techniques}>{t}</li>
                </ul>
                <p :if={s.watch_out} class="mb-3 text-sm italic text-muted-foreground">
                  {s.watch_out}
                </p>
                <div class="flex gap-2">
                  <.button
                    id={"save-suggestion-#{s.id}"}
                    phx-click="save-suggestion"
                    phx-value-id={s.id}
                  >
                    {gettext("Save")}
                  </.button>
                  <.button
                    id={"discard-suggestion-#{s.id}"}
                    variant="outline"
                    phx-click="discard-suggestion"
                    phx-value-id={s.id}
                  >
                    {gettext("Discard")}
                  </.button>
                </div>
              </div>
            </div>
          </.card>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
