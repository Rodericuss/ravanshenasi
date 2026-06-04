defmodule RavanshenasiWeb.Router do
  use RavanshenasiWeb, :router

  import RavanshenasiWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug RavanshenasiWeb.Plugs.Locale
    plug :put_root_layout, html: {RavanshenasiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RavanshenasiWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", RavanshenasiWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ravanshenasi, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RavanshenasiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", RavanshenasiWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [
        {RavanshenasiWeb.Plugs.Locale, :set_locale},
        {RavanshenasiWeb.UserAuth, :require_authenticated}
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      live "/linhas", FrameworkLive.Index, :index
    end

    live_session :require_clinical,
      on_mount: [
        {RavanshenasiWeb.Plugs.Locale, :set_locale},
        {RavanshenasiWeb.UserAuth, :require_authenticated},
        {RavanshenasiWeb.UserAuth, :require_clinical_access}
      ] do
      live "/pacientes", PatientLive.Index, :index
      live "/pacientes/novo", PatientLive.Form, :new
      live "/pacientes/:id", PatientLive.Show, :show
      live "/pacientes/:id/editar", PatientLive.Form, :edit
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", RavanshenasiWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        {RavanshenasiWeb.Plugs.Locale, :set_locale},
        {RavanshenasiWeb.UserAuth, :mount_current_scope}
      ] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
      live "/registrar/clinica", Org.RegistrationLive, :new
      live "/convites/:token", Org.AcceptInvitationLive, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  scope "/", RavanshenasiWeb do
    pipe_through [:browser]

    live_session :require_clinic_admin,
      on_mount: [
        {RavanshenasiWeb.Plugs.Locale, :set_locale},
        {RavanshenasiWeb.UserAuth, :require_authenticated},
        {RavanshenasiWeb.UserAuth, :require_clinic_admin}
      ] do
      live "/equipe", Org.MembersLive, :index
    end
  end
end
