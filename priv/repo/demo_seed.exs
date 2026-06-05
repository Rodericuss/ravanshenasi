# Demo seed for the visual tour. Run with: mix run priv/repo/demo_seed.exs
# Idempotent-ish: reuses the demo user if it already exists.
alias Ravanshenasi.{Accounts, AudioMessages, Frameworks, Patients, Records, Repo, Sessions}
alias Ravanshenasi.Accounts.Scope

email = "demo@psicare.dev"

user =
  case Accounts.get_user_by_email(email) do
    nil ->
      {:ok, u} =
        Accounts.register_solo(%{
          name: "Dra. Marina Alves",
          email: email,
          office_name: "Consultório Marina"
        })

      u

    u ->
      u
  end

user = Repo.preload(user, :tenant)
scope = Scope.for_user(user) |> Scope.put_tenant(user.tenant)

if Patients.list_patients(scope) == [] do
  {:ok, p1} =
    Patients.create_patient(scope, %{name: "Ana Beatriz", chief_complaint: "Ansiedade generalizada"})

  {:ok, _p2} =
    Patients.create_patient(scope, %{name: "Carlos Henrique", chief_complaint: "Insônia"})

  {:ok, _p3} = Patients.create_patient(scope, %{name: "Júlia Santos", chief_complaint: "Processo de luto"})

  fw = Frameworks.list_frameworks(scope) |> hd()
  :ok = Patients.activate_framework(scope, p1, fw)

  {:ok, sess} =
    Sessions.create_session(scope, p1, %{
      notes: "Paciente relatou melhora no padrão de sono após introdução de técnicas de respiração.",
      date: DateTime.utc_now() |> DateTime.truncate(:second)
    })

  {:ok, %{record: rec}} = Sessions.finalize_session(scope, sess)

  {:ok, _} =
    Records.complete(
      scope,
      rec,
      "S: Paciente relata melhora no sono.\nO: Postura mais relaxada.\nA: Resposta positiva às técnicas.\nP: Manter exercícios de respiração.",
      "openai:gpt-4o-mini"
    )

  {:ok, _} =
    AudioMessages.create_audio_message(scope, p1, %{
      audio_path: "/tmp/demo.ogg",
      original_filename: "audio_paciente_ana.ogg",
      tone: :empathetic
    })
end

{encoded, user_token} = Accounts.UserToken.build_email_token(user, "login")
Repo.insert!(user_token)
IO.puts("MAGIC_URL=/users/log-in/#{encoded}")
