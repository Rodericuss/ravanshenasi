defmodule RavanshenasiWeb.PatientLive.Form do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Patients
  alias Ravanshenasi.Patients.Patient

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: gettext("New patient"),
      patient: %Patient{},
      form: to_form(Patients.change_patient(%Patient{}))
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    patient = Patients.get_patient!(socket.assigns.current_scope, id)

    assign(socket,
      page_title: gettext("Edit patient"),
      patient: patient,
      form: to_form(Patients.change_patient(patient))
    )
  end

  @impl true
  def handle_event("validate", %{"patient" => params}, socket) do
    form =
      socket.assigns.patient
      |> Patients.change_patient(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"patient" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case Patients.create_patient(socket.assigns.current_scope, params) do
      {:ok, p} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Patient created"))
         |> push_navigate(to: ~p"/pacientes/#{p.id}")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Not authorized"))
         |> push_navigate(to: ~p"/pacientes")}
    end
  end

  defp save(socket, :edit, params) do
    case Patients.update_patient(socket.assigns.current_scope, socket.assigns.patient, params) do
      {:ok, p} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Patient updated"))
         |> push_navigate(to: ~p"/pacientes/#{p.id}")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Not authorized"))
         |> push_navigate(to: ~p"/pacientes")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {@page_title}
        <:subtitle :if={@live_action == :edit}>
          {gettext("Update patient information")}
        </:subtitle>
      </.header>

      <.card class="max-w-2xl">
        <.form for={@form} id="patient-form" phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} label={gettext("Name")} required />
          <div class="grid gap-4 sm:grid-cols-2">
            <.input field={@form[:birth_date]} type="date" label={gettext("Birth date")} />
            <.input field={@form[:phone]} label={gettext("Phone")} />
          </div>
          <.input field={@form[:email]} type="email" label={gettext("Email")} />
          <.input field={@form[:chief_complaint]} type="textarea" label={gettext("Chief complaint")} />
          <.input
            field={@form[:relevant_history]}
            type="textarea"
            label={gettext("Relevant history")}
          />
          <.input
            field={@form[:status]}
            type="select"
            label={gettext("Status")}
            options={[
              {gettext("Active"), :active},
              {gettext("Inactive"), :inactive},
              {gettext("Waitlist"), :waitlist}
            ]}
          />
          <div class="flex gap-3 pt-2">
            <.button phx-disable-with={gettext("Saving...")}>{gettext("Save")}</.button>
            <.button variant="outline" navigate={~p"/pacientes"}>{gettext("Cancel")}</.button>
          </div>
        </.form>
      </.card>
    </Layouts.app>
    """
  end
end
