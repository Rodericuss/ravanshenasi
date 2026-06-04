defmodule Ravanshenasi.Records.GenerateSoapWorker do
  @moduledoc "Oban worker that calls the AI facade to generate SOAP notes for a record."

  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Ravanshenasi.Accounts.{Scope, Tenant, User}
  alias Ravanshenasi.{AI, Patients, Records, Sessions}
  alias Ravanshenasi.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max}) do
    %{"record_id" => rid, "user_id" => uid, "tenant_id" => tid} = args

    with {:ok, scope} <- build_scope(uid, tid),
         %Records.Record{} = record <- Records.get_record(scope, rid) do
      {:ok, _} = Records.mark_generating(scope, record)
      input = build_input(scope, record)

      case AI.generate_soap(input) do
        {:ok, %{content: content, provider: provider, model: model}} ->
          {:ok, _} = Records.complete(scope, record, content, "#{provider}:#{model}")
          :ok

        {:error, reason} when attempt >= max ->
          {:ok, _} = Records.fail(scope, record, reason)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:discard, :not_found}
      {:error, :not_found} -> {:discard, :not_found}
    end
  end

  defp build_scope(uid, tid) do
    Repo.with_auth_bypass(fn ->
      # `%User{tenant_id: ^tid}` casa só se o user PERTENCE ao tenant do job.
      with %User{tenant_id: ^tid} = user <- Repo.get(User, uid),
           %Tenant{} = tenant <- Repo.get(Tenant, tid) do
        {:ok, Scope.for_user(user) |> Scope.put_tenant(tenant)}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  defp build_input(scope, record) do
    patient = Patients.get_patient!(scope, record.patient_id)
    session = Sessions.get_session!(scope, record.session_id)

    %{
      patient: patient,
      frameworks: Patients.list_patient_frameworks(scope, patient),
      previous_sessions: Sessions.recent_finalized(scope, patient, session.id),
      current_notes: session.notes
    }
  end
end
