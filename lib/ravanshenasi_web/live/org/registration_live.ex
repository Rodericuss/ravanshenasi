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
            Cadastrar clínica
            <:subtitle>
              Já tem conta?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Entrar
              </.link>
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="clinic-registration-form" phx-submit="save">
          <.input field={@form[:clinic_name]} type="text" label="Nome da clínica" required />
          <.input field={@form[:name]} type="text" label="Seu nome" required />
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
          />

          <.button phx-disable-with="Criando clínica..." class="btn btn-primary w-full">
            Criar clínica
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
           email: params["email"]
         }) do
      {:ok, user} ->
        # Mesmo fluxo do registro solo: envia o magic link de confirmação.
        Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))

        {:noreply,
         socket
         |> put_flash(:info, "Clínica criada. Confira seu email para confirmar.")
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Não foi possível criar a clínica. Verifique os dados.")
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
