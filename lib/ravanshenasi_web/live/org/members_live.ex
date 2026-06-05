defmodule RavanshenasiWeb.Org.MembersLive do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl">
        <.header>
          {gettext("Team")}
          <:subtitle>{gettext("Clinic members")}</:subtitle>
        </.header>

        <div class="mt-4">
          <.table id="members-table" rows={@members}>
            <:col :let={member} label={gettext("Name")}>{member.name}</:col>
            <:col :let={member} label={gettext("Email")}>{member.email}</:col>
            <:col :let={member} label={gettext("Role")}>{member.role}</:col>
          </.table>
        </div>

        <div class="mt-8">
          <.header>
            {gettext("Invite member")}
          </.header>

          <.form for={@invite_form} id="invite-form" phx-submit="invite">
            <.input
              field={@invite_form[:email]}
              type="email"
              label={gettext("Invitee email")}
              required
            />

            <.button phx-disable-with={gettext("Inviting...")} class="w-full mt-2">
              {gettext("Invite therapist")}
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
         |> put_flash(:info, gettext("Invitation sent to %{email}.", email: email))
         |> assign(members: members, invite_form: to_form(%{"email" => ""}, as: :invitation))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not send the invitation."))
         |> assign(invite_form: to_form(%{"email" => email}, as: :invitation))}
    end
  end
end
