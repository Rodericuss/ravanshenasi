defmodule RavanshenasiWeb.Org.RegistrationLive do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            {gettext("Register clinic")}
            <:subtitle>
              {gettext("Already have an account?")}
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                {gettext("Log in")}
              </.link>
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="clinic-registration-form" phx-submit="save">
          <.input field={@form[:clinic_name]} type="text" label={gettext("Clinic name")} required />
          <.input field={@form[:name]} type="text" label={gettext("Your name")} required />
          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password (optional)")}
            autocomplete="new-password"
          />

          <.button phx-disable-with={gettext("Creating clinic...")} class="btn btn-primary w-full">
            {gettext("Create clinic")}
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: RavanshenasiWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    form = to_form(%{"clinic_name" => "", "name" => "", "email" => ""}, as: :clinic)
    {:ok, assign(socket, form: form)}
  end

  @impl true
  def handle_event("save", %{"clinic" => params}, socket) do
    case Accounts.register_clinic(%{
           clinic_name: params["clinic_name"],
           name: params["name"],
           email: params["email"],
           password: params["password"]
         }) do
      {:ok, user} ->
        # Same flow as solo registration: sends the confirmation magic link.
        Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))

        {:noreply,
         socket
         |> put_flash(:info, gettext("Clinic created. Check your email to confirm."))
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not create the clinic. Check the details."))
         |> assign(
           form:
             to_form(
               %{
                 "clinic_name" => params["clinic_name"],
                 "name" => params["name"],
                 "email" => params["email"]
               },
               as: :clinic
             )
         )}
    end
  end
end
