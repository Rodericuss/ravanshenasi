defmodule Ravanshenasi.Sessions do
  @moduledoc "Therapy sessions, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Patients.Patient
  alias Ravanshenasi.Records
  alias Ravanshenasi.Records.GenerateSoapWorker
  alias Ravanshenasi.Records.Record
  alias Ravanshenasi.Repo
  alias Ravanshenasi.Sessions.Session

  def list_sessions(%Scope{} = scope, %Patient{} = patient) do
    transact_tenant(scope, fn ->
      Session
      |> scoped(scope)
      |> where([s], s.patient_id == ^patient.id)
      |> order_by([s], desc: s.date)
      |> Repo.all()
    end)
  end

  def get_session(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> Session |> scoped(scope) |> Repo.get(id) end)

  def get_session!(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> Session |> scoped(scope) |> Repo.get!(id) end)

  @doc "Sessão por id garantindo que pertence ao paciente da rota (além do scope)."
  def get_session_for_patient(%Scope{} = scope, %{id: patient_id}, id) do
    transact_tenant(scope, fn ->
      Session
      |> scoped(scope)
      |> where([s], s.patient_id == ^patient_id)
      |> Repo.get(id)
    end)
  end

  @doc """
  Cria sessão. NÃO confia no struct passado: recarrega o paciente por query
  escopada (tenant_id + user_id) antes de inserir.
  """
  def create_session(%Scope{} = scope, %{id: patient_id}, attrs) do
    if Scope.clinical_access?(scope),
      do: insert_session(scope, patient_id, attrs),
      else: {:error, :unauthorized}
  end

  defp insert_session(scope, patient_id, attrs) do
    transact_tenant(scope, fn ->
      case Patient |> patient_scoped(scope) |> Repo.get(patient_id) do
        nil ->
          {:error, :unauthorized}

        patient ->
          %Session{
            tenant_id: scope.tenant.id,
            user_id: scope.user.id,
            patient_id: patient.id,
            status: :draft
          }
          |> Session.changeset(attrs)
          |> Repo.insert()
      end
    end)
  end

  @doc """
  Atualiza sessão. NÃO confia no struct: recarrega por query escopada usando
  apenas o id antes de operar.
  """
  def update_session(%Scope{} = scope, %{id: id}, attrs) do
    transact_tenant(scope, fn ->
      case Session |> scoped(scope) |> Repo.get(id) do
        nil -> {:error, :unauthorized}
        %Session{status: :finalized} -> {:error, :finalized}
        session -> session |> Session.changeset(attrs) |> Repo.update()
      end
    end)
  end

  def change_session(%Session{} = session, attrs \\ %{}), do: Session.changeset(session, attrs)

  @doc "Finaliza a sessão (draft→finalized), cria o record pending e enfileira o job. Atômico."
  def finalize_session(%Scope{} = scope, %{id: id}) do
    if Scope.clinical_access?(scope), do: do_finalize(scope, id), else: {:error, :unauthorized}
  end

  # Repo.transaction PRÓPRIO (não transact_tenant, que LEVANTA em rollback). O UPDATE
  # condicional com RETURNING (`select: s`): (1) serializa finalizações concorrentes — só
  # quem vê status=:draft vence; (2) o WHERE inclui user_id, então sessão de outro
  # profissional do mesmo tenant não é tocada (0 linhas); (3) devolve a LINHA DO BANCO, de
  # onde derivamos tenant/user/patient do record (nunca do struct do caller). Reseta o GUC
  # no sucesso (como o transact_tenant); no rollback o Postgres reverte o SET LOCAL.
  defp do_finalize(scope, id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT set_config('app.current_tenant_id', $1, true)", [scope.tenant.id])
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {_count, rows} =
        Repo.update_all(
          from(s in Session,
            where:
              s.id == ^id and s.tenant_id == ^scope.tenant.id and
                s.user_id == ^scope.user.id and s.status == :draft,
            select: s
          ),
          set: [status: :finalized, updated_at: now]
        )

      case rows do
        [] ->
          Repo.rollback(:already_finalized)

        [session] ->
          record =
            %Record{
              tenant_id: session.tenant_id,
              user_id: session.user_id,
              session_id: session.id,
              patient_id: session.patient_id,
              generation_status: :pending
            }
            |> Ecto.Changeset.change()
            |> Repo.insert!()

          Oban.insert!(GenerateSoapWorker.new(Records.job_args(record)))
          Repo.query!("SELECT set_config('app.current_tenant_id', '', true)")
          %{session: session, record: record}
      end
    end)
  end

  @doc "Últimas `limit` sessões finalizadas do paciente, EXCLUINDO `exclude_session_id`."
  def recent_finalized(%Scope{} = scope, %Patient{} = patient, exclude_session_id, limit \\ 3) do
    transact_tenant(scope, fn ->
      Session
      |> scoped(scope)
      |> where(
        [s],
        s.patient_id == ^patient.id and s.status == :finalized and s.id != ^exclude_session_id
      )
      |> order_by([s], desc: s.date)
      |> limit(^limit)
      |> Repo.all()
    end)
  end

  # scope por praticante: tenant_id + user_id
  defp scoped(query, scope),
    do: from(s in query, where: s.tenant_id == ^scope.tenant.id and s.user_id == ^scope.user.id)

  # scope por paciente: recarrega o patient garantindo ownership
  defp patient_scoped(query, scope),
    do: from(p in query, where: p.tenant_id == ^scope.tenant.id and p.user_id == ^scope.user.id)

  defdelegate transact_tenant(scope, fun), to: Repo
end
