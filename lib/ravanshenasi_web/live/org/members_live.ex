defmodule RavanshenasiWeb.Org.MembersLive do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl">
        <.header>
          Equipe
          <:subtitle>Membros da clínica</:subtitle>
        </.header>

        <table class="w-full mt-4">
          <thead>
            <tr>
              <th class="text-left">Nome</th>
              <th class="text-left">Email</th>
              <th class="text-left">Papel</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={member <- @members}>
              <td>{member.name}</td>
              <td>{member.email}</td>
              <td>{member.role}</td>
            </tr>
          </tbody>
        </table>

        <div class="mt-8">
          <.header>
            Convidar membro
          </.header>

          <.form for={@invite_form} id="invite-form" phx-submit="invite">
            <.input field={@invite_form[:email]} type="email" label="Email do convidado" required />

            <.button phx-disable-with="Convidando..." class="btn btn-primary w-full">
              Enviar convite
            </.button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    members = Accounts.list_members(socket.assigns.current_scope)
    invite_form = to_form(%{"email" => ""}, as: :invitation)
    {:ok, assign(socket, members: members, invite_form: invite_form)}
  end

  @impl true
  def handle_event("invite", %{"invitation" => %{"email" => email}}, socket) do
    case Accounts.create_invitation(socket.assigns.current_scope, %{
           email: email,
           role: :therapist
         }) do
      {:ok, _raw_token} ->
        members = Accounts.list_members(socket.assigns.current_scope)

        {:noreply,
         socket
         |> put_flash(:info, "Convite enviado para #{email}.")
         |> assign(members: members, invite_form: to_form(%{"email" => ""}, as: :invitation))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Não foi possível enviar o convite.")
         |> assign(invite_form: to_form(%{"email" => email}, as: :invitation))}
    end
  end
end
