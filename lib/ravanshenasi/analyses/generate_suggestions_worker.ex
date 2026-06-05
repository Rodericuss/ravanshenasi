defmodule Ravanshenasi.Analyses.GenerateSuggestionsWorker do
  @moduledoc "Oban worker that calls the AI facade to suggest therapy approaches for an analysis."

  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Ravanshenasi.Accounts.{Scope, Tenant, User}
  alias Ravanshenasi.{AI, Analyses, Patients, Records}
  alias Ravanshenasi.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max}) do
    %{"analysis_id" => aid, "user_id" => uid, "tenant_id" => tid} = args

    with {:ok, scope} <- build_scope(uid, tid),
         %Analyses.Analysis{} = analysis <- Analyses.get_analysis(scope, aid) do
      process(scope, analysis, attempt, max)
    else
      nil -> {:discard, :not_found}
      {:error, :not_found} -> {:discard, :not_found}
    end
  end

  # Terminal (done/error): the job already completed in a previous at-least-once Oban
  # execution. Do not call AI again. The context is also idempotent as a safety net.
  defp process(_scope, %Analyses.Analysis{generation_status: st}, _attempt, _max)
       when st in [:done, :error],
       do: :ok

  defp process(scope, analysis, attempt, max) do
    {:ok, _} = Analyses.mark_generating(scope, analysis)
    input = build_input(scope, analysis)

    case AI.generate_suggestions(input) do
      {:ok, %{suggestions: suggestions, provider: provider, model: model}} ->
        {:ok, _} = Analyses.complete(scope, analysis, suggestions, "#{provider}:#{model}")
        :ok

      {:error, reason} when attempt >= max ->
        {:ok, _} = Analyses.fail(scope, analysis, reason)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_scope(uid, tid) do
    Repo.with_auth_bypass(fn ->
      # `%User{tenant_id: ^tid}` matches only if the user belongs to the job tenant.
      with %User{tenant_id: ^tid} = user <- Repo.get(User, uid),
           %Tenant{} = tenant <- Repo.get(Tenant, tid) do
        {:ok, Scope.for_user(user) |> Scope.put_tenant(tenant)}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  defp build_input(scope, analysis) do
    patient = Patients.get_patient!(scope, analysis.patient_id)

    %{
      patient: patient,
      frameworks: Patients.list_patient_frameworks(scope, patient),
      recent_records: Records.recent_done_records(scope, %{id: patient.id})
    }
  end
end
