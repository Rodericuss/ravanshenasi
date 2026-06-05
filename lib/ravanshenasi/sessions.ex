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

  @doc "Fetches a session by id, ensuring it belongs to the routed patient and current scope."
  def get_session_for_patient(%Scope{} = scope, %{id: patient_id}, id) do
    transact_tenant(scope, fn ->
      Session
      |> scoped(scope)
      |> where([s], s.patient_id == ^patient_id)
      |> Repo.get(id)
    end)
  end

  @doc """
  Creates a session. Does not trust the incoming struct: reloads the patient through
  a scoped query (tenant_id + user_id) before inserting.
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
  Updates a session. Does not trust the incoming struct: reloads through a scoped
  query using only the id before operating.
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

  @doc "Finalizes the session, creates the pending record, and enqueues the job atomically."
  def finalize_session(%Scope{} = scope, %{id: id}) do
    if Scope.clinical_access?(scope), do: do_finalize(scope, id), else: {:error, :unauthorized}
  end

  # Own Repo.transaction call (not transact_tenant, which raises on rollback). The
  # conditional UPDATE with RETURNING (`select: s`): (1) serializes concurrent
  # finalizations so only the caller that sees status=:draft wins; (2) includes user_id
  # in the WHERE, so another practitioner in the same tenant is untouched (0 rows);
  # (3) returns the database row, from which we derive tenant/user/patient for the
  # record, never from the caller's struct. Resets the GUC on success like
  # transact_tenant; on rollback Postgres reverts SET LOCAL.
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
          # 0 rows: distinguishes "already finalized by the owner" from "access to a
          # foreign session". The scoped query (tenant_id + user_id) only finds owned rows.
          Repo.rollback(finalize_failure_reason(scope, id))

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

  defp finalize_failure_reason(scope, id) do
    case Session |> scoped(scope) |> Repo.get(id) do
      nil -> :unauthorized
      _ -> :already_finalized
    end
  end

  @doc "Lists the patient's latest finalized sessions, excluding `exclude_session_id`."
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

  @doc "Lists the owner's most recent sessions across patients, scoped, date desc with nulls last, and preloading :patient."
  def list_recent(%Scope{} = scope, limit \\ 5) do
    transact_tenant(scope, fn ->
      Session
      |> scoped(scope)
      |> order_by([s], desc_nulls_last: s.date, desc: s.inserted_at)
      |> limit(^limit)
      |> preload(:patient)
      |> Repo.all()
    end)
  end

  # Practitioner scope: tenant_id + user_id.
  defp scoped(query, scope),
    do: from(s in query, where: s.tenant_id == ^scope.tenant.id and s.user_id == ^scope.user.id)

  # Patient scope: reloads the patient while enforcing ownership.
  defp patient_scoped(query, scope),
    do: from(p in query, where: p.tenant_id == ^scope.tenant.id and p.user_id == ^scope.user.id)

  defdelegate transact_tenant(scope, fun), to: Repo
end
