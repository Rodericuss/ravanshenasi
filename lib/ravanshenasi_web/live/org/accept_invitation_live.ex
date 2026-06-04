defmodule RavanshenasiWeb.Org.AcceptInvitationLive do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Aceitar convite
            <:subtitle>
              Preencha seus dados para entrar na equipe.
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="accept-invitation-form" phx-submit="accept">
          <.input field={@form[:name]} type="text" label="Seu nome" required />
          <.input
            field={@form[:password]}
            type="password"
            label="Senha (opcional)"
            autocomplete="new-password"
          />

          <.button phx-disable-with="Entrando..." class="btn btn-primary w-full">
            Entrar na equipe
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok,
     socket
     |> put_flash(:error, "Saia da sua conta para aceitar um convite em outra.")
     |> redirect(to: RavanshenasiWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(%{"token" => token}, _session, socket) do
    form = to_form(%{"name" => "", "password" => ""}, as: :user)
    {:ok, assign(socket, form: form, token: token)}
  end

  @impl true
  def handle_event("accept", %{"user" => params}, socket) do
    attrs = %{
      name: params["name"],
      password: params["password"] |> presence()
    }

    case Accounts.accept_invitation(socket.assigns.token, attrs) do
      {:ok, user} ->
        # User already confirmed by the acceptance — generates a magic link and takes
        # them directly to the screen that establishes the session.
        login_token = Accounts.generate_login_token(user)

        {:noreply,
         socket
         |> put_flash(:info, "Bem-vindo(a) à equipe!")
         |> redirect(to: ~p"/users/log-in/#{login_token}")}

      {:error, reason} ->
        msg = invitation_error_message(reason)

        {:noreply,
         socket
         |> put_flash(:error, msg)
         |> assign(form: to_form(%{"name" => params["name"], "password" => ""}, as: :user))}
    end
  end

  defp invitation_error_message(:invalid_invitation), do: "Convite inválido."
  defp invitation_error_message(:expired), do: "Convite expirado."
  defp invitation_error_message(:already_accepted), do: "Convite já utilizado."
  defp invitation_error_message(_), do: "Não foi possível aceitar o convite."

  # nil or empty string → nil (password is optional)
  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(v), do: v
end
