defmodule RavanshenasiWeb.SessionLive.Form do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.{Patients, Sessions}
  alias Ravanshenasi.Sessions.Session

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, %{"patient_id" => pid}) do
    scope = socket.assigns.current_scope
    patient = Patients.get_patient!(scope, pid)

    assign(socket,
      page_title: gettext("New session"),
      patient: patient,
      session: %Session{},
      form: to_form(Sessions.change_session(%Session{}))
    )
  end

  @impl true
  def handle_event("validate", %{"session" => params}, socket) do
    form =
      socket.assigns.session
      |> Sessions.change_session(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"session" => params}, socket) do
    scope = socket.assigns.current_scope
    patient = socket.assigns.patient

    case Sessions.create_session(scope, patient, params) do
      {:ok, session} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Session created"))
         |> push_navigate(to: ~p"/pacientes/#{patient.id}/sessoes/#{session.id}")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not create session"))
         |> push_navigate(to: ~p"/pacientes/#{patient.id}/sessoes")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>{@page_title}</.header>
      <.form for={@form} id="session-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:notes]} type="textarea" label={gettext("Notes")} />
        <.input field={@form[:duration_minutes]} type="number" label={gettext("Duration (minutes)")} />
        <.button phx-disable-with={gettext("Saving...")}>{gettext("Save")}</.button>
      </.form>
    </Layouts.app>
    """
  end
end
