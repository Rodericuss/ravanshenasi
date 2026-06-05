defmodule Ravanshenasi.Analyses do
  @moduledoc "Therapy-approach suggestions, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Analyses.{Analysis, GenerateSuggestionsWorker, Suggestion}
  alias Ravanshenasi.Patients.{Patient, PatientFramework}
  alias Ravanshenasi.Repo

  @pubsub Ravanshenasi.PubSub
  @active_statuses [:pending, :generating]

  @doc """
  Dispara a análise de um paciente. NÃO confia no struct: recarrega o paciente por
  query escopada. Idempotente (1 análise ativa por paciente). Bloqueia sem frameworks
  ativos. Tudo num único transact_tenant (não aninhar — transact_tenant reseta o GUC).
  """
  def analyze_patient(%Scope{} = scope, %{id: patient_id}) do
    if Scope.clinical_access?(scope),
      do: do_analyze(scope, patient_id),
      else: {:error, :unauthorized}
  end

  defp do_analyze(scope, patient_id) do
    transact_tenant(scope, fn ->
      case Patient |> patient_scoped(scope) |> Repo.get(patient_id) do
        nil -> {:error, :unauthorized}
        patient -> analyze_loaded(scope, patient)
      end
    end)
  end

  defp analyze_loaded(scope, patient) do
    cond do
      not has_active_frameworks?(scope, patient) -> {:error, :no_active_frameworks}
      active = active_analysis(scope, patient.id) -> {:ok, active}
      true -> insert_pending(scope, patient.id)
    end
  end

  defp insert_pending(scope, patient_id) do
    attrs = %{tenant_id: scope.tenant.id, user_id: scope.user.id, patient_id: patient_id}

    case attrs |> Analysis.insert_changeset() |> Repo.insert() do
      {:ok, analysis} ->
        Oban.insert!(GenerateSuggestionsWorker.new(job_args(analysis)))
        {:ok, analysis}

      {:error, changeset} ->
        resolve_active_race(scope, patient_id, changeset)
    end
  end

  # SÓ trata como corrida do índice parcial "1 ativa por paciente". Qualquer outro erro
  # (FK, validação, outra constraint) é bug real e sobe como {:error, changeset} — nunca
  # vira {:ok, nil} silencioso. O insert falho roda em savepoint (unique_constraint
  # declarado), então a transação externa segue viva e o active_analysis abaixo funciona.
  defp resolve_active_race(scope, patient_id, changeset) do
    if active_constraint_error?(changeset) do
      case active_analysis(scope, patient_id) do
        # corrida real: a outra requisição venceu — devolve a ativa (idempotente)
        %Analysis{} = active -> {:ok, active}
        # constraint disparou mas não há ativa agora (caso degenerado): devolve o erro real
        nil -> {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  # O índice parcial é :analyses_one_active_per_patient (ver migration). Quando ele dispara,
  # o erro vem na 1ª coluna do unique_constraint com constraint_name batendo.
  defp active_constraint_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      opts[:constraint] == :unique and opts[:constraint_name] == "analyses_one_active_per_patient"
    end)
  end

  defp has_active_frameworks?(scope, patient) do
    Repo.exists?(
      from(pf in PatientFramework,
        where: pf.patient_id == ^patient.id and pf.tenant_id == ^scope.tenant.id
      )
    )
  end

  defp active_analysis(scope, patient_id) do
    Analysis
    |> scoped(scope)
    |> where([a], a.patient_id == ^patient_id and a.generation_status in @active_statuses)
    |> Repo.one()
  end

  def get_analysis(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> Analysis |> scoped(scope) |> Repo.get(id) end)

  def get_analysis!(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> Analysis |> scoped(scope) |> Repo.get!(id) end)

  # --- internos (worker, scope reconstruído) — recarregam, não confiam no struct.
  # Idempotentes: Oban é at-least-once, então reexecução não pode regredir nem duplicar. ---

  @doc "Marca generating. No-op em done/error (não regride). Broadcast quando aplicável."
  def mark_generating(%Scope{} = scope, %{id: id}) do
    res =
      transact_tenant(scope, fn ->
        case Analysis |> scoped(scope) |> Repo.get(id) do
          nil ->
            {:error, :unauthorized}

          %Analysis{generation_status: st} = a when st in @active_statuses ->
            a |> Analysis.status_changeset(%{generation_status: :generating}) |> Repo.update()

          # done/error são terminais: não regride numa reexecução de job
          %Analysis{} = a ->
            {:ok, a}
        end
      end)

    with {:ok, a} <- res, do: broadcast(a)
    res
  end

  def fail(%Scope{} = scope, %{id: id}, reason),
    do: set_status(scope, id, %{generation_status: :error, error_reason: inspect(reason)})

  @doc """
  Marca done e insere as N suggestions (tenant/user derivados da analysis), depois broadcast.
  Idempotente: análise já `done` é no-op (não reinsere cards numa reexecução de job).
  """
  def complete(%Scope{} = scope, %{id: id}, suggestions, model_used) do
    res =
      transact_tenant(scope, fn ->
        case Analysis |> scoped(scope) |> Repo.get(id) do
          nil ->
            {:error, :unauthorized}

          # já concluída: idempotente — não reinsere (Oban at-least-once)
          %Analysis{generation_status: :done} = a ->
            {:ok, a}

          analysis ->
            {:ok, done} =
              analysis
              |> Analysis.status_changeset(%{generation_status: :done, model_used: model_used})
              |> Repo.update()

            insert_suggestions(done, suggestions)
            {:ok, done}
        end
      end)

    with {:ok, a} <- res, do: broadcast(a)
    res
  end

  @doc "Cards de uma análise (do dono). Read escopa por id — struct alheio não retorna nada."
  def list_suggestions(%Scope{} = scope, %{id: analysis_id}) do
    transact_tenant(scope, fn ->
      Suggestion
      |> scoped(scope)
      |> where([sg], sg.analysis_id == ^analysis_id)
      |> order_by([sg], asc: sg.inserted_at)
      |> Repo.all()
    end)
  end

  defp insert_suggestions(%Analysis{} = analysis, suggestions) do
    Enum.each(suggestions, fn s ->
      %{
        tenant_id: analysis.tenant_id,
        user_id: analysis.user_id,
        analysis_id: analysis.id,
        framework_name: s.framework,
        justification: s.justification,
        techniques: s.techniques,
        watch_out: s.watch_out,
        status: :suggested
      }
      |> Suggestion.insert_changeset()
      |> Repo.insert!()
    end)
  end

  defp set_status(scope, id, changes) do
    res =
      transact_tenant(scope, fn ->
        case Analysis |> scoped(scope) |> Repo.get(id) do
          nil -> {:error, :unauthorized}
          a -> a |> Analysis.status_changeset(changes) |> Repo.update()
        end
      end)

    with {:ok, a} <- res, do: broadcast(a)
    res
  end

  @doc "Histórico de análises do paciente (do dono), mais recentes primeiro. Read escopa por id."
  def list_analyses(%Scope{} = scope, %{id: patient_id}) do
    transact_tenant(scope, fn ->
      Analysis
      |> scoped(scope)
      |> where([a], a.patient_id == ^patient_id)
      |> order_by([a], desc: a.inserted_at)
      |> Repo.all()
    end)
  end

  def save_suggestion(%Scope{} = scope, %{id: id}), do: set_suggestion_status(scope, id, :saved)

  def discard_suggestion(%Scope{} = scope, %{id: id}),
    do: set_suggestion_status(scope, id, :discarded)

  defp set_suggestion_status(scope, id, status) do
    transact_tenant(scope, fn ->
      case Suggestion |> scoped(scope) |> Repo.get(id) do
        nil -> {:error, :unauthorized}
        sg -> sg |> Suggestion.status_changeset(%{status: status}) |> Repo.update()
      end
    end)
  end

  # --- pubsub / job ---
  def subscribe(analysis_id), do: Phoenix.PubSub.subscribe(@pubsub, "analysis:#{analysis_id}")

  def broadcast(%Analysis{} = a),
    do: Phoenix.PubSub.broadcast(@pubsub, "analysis:#{a.id}", {:analysis_updated, a})

  def job_args(%Analysis{} = a),
    do: %{analysis_id: a.id, user_id: a.user_id, tenant_id: a.tenant_id}

  # scope por praticante: tenant_id + user_id (vale pra Analysis e Suggestion)
  defp scoped(query, scope),
    do: from(x in query, where: x.tenant_id == ^scope.tenant.id and x.user_id == ^scope.user.id)

  defp patient_scoped(query, scope),
    do: from(p in query, where: p.tenant_id == ^scope.tenant.id and p.user_id == ^scope.user.id)

  defdelegate transact_tenant(scope, fun), to: Repo
end
