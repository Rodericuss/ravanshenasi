import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ravanshenasi, Ravanshenasi.Repo,
  username: "ravanshenasi_app",
  password: "ravanshenasi_app",
  hostname: "localhost",
  database: "ravanshenasi_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ravanshenasi, RavanshenasiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "hGr9wENX7W7FrQwAZIMhI6iaViOvm8gn1unJwoJckqAqhDyjwy+vMjubgqXNMyY8",
  server: false

# In test we don't send emails
config :ravanshenasi, Ravanshenasi.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Oban: jobs don't run automatically in tests — use Oban.Testing.
config :ravanshenasi, Oban, testing: :manual

# AI: deterministic stub provider (no network).
config :ravanshenasi, Ravanshenasi.AI,
  order: [:stub],
  providers: %{stub: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, model: "stub-model"}},
  transcription: %{
    order: [:stub],
    providers: %{stub: %{client: Ravanshenasi.AI.Transcriber.Stub, text: "olá, tudo bem?"}}
  }

# Req.Test plug for the OpenAI client (used in Task 7).
config :ravanshenasi, :ai_req_plug, {Req.Test, Ravanshenasi.AI.Client.OpenAI}
config :ravanshenasi, :transcriber_req_plug, {Req.Test, Ravanshenasi.AI.Transcriber.OpenAI}

# Keep tests in English (assertions check English msgids)
config :ravanshenasi, RavanshenasiWeb.Gettext, default_locale: "en"
