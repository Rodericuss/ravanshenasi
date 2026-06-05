defmodule RavanshenasiWeb.UserLive.Confirmation do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <.header>
          {gettext("Welcome")} {@user.email}
        </.header>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <div class="space-y-3">
            <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with={gettext("Confirming...")}
              class="w-full"
            >
              {gettext("Confirm and stay logged in")}
            </.button>
            <.button
              phx-disable-with={gettext("Confirming...")}
              variant="outline"
              class="w-full"
            >
              {gettext("Confirm and log in only this time")}
            </.button>
          </div>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <div class="space-y-3">
            <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
            <%= if @current_scope do %>
              <.button phx-disable-with={gettext("Logging in...")} class="w-full">
                {gettext("Log in")}
              </.button>
            <% else %>
              <.button
                name={@form[:remember_me].name}
                value="true"
                phx-disable-with={gettext("Logging in...")}
                class="w-full"
              >
                {gettext("Keep me logged in on this device")}
              </.button>
              <.button
                phx-disable-with={gettext("Logging in...")}
                variant="outline"
                class="w-full"
              >
                {gettext("Log me in only this time")}
              </.button>
            <% end %>
          </div>
        </.form>

        <p
          :if={!@user.confirmed_at}
          class="rounded-md bg-muted/40 p-3 text-sm text-muted-foreground mt-6"
        >
          {gettext("Tip: If you prefer passwords, you can enable them in the user settings.")}
        </p>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Magic link is invalid or it has expired."))
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
