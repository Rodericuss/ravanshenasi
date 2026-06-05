defmodule Ravanshenasi.Records do
  @moduledoc "SOAP records, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Records.GenerateSoapWorker
  alias Ravanshenasi.Records.Record
  alias Ravanshenasi.Repo
  alias Ravanshenasi.Sessions.Session

  @pubsub Ravanshenasi.PubSub

  def get_record(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> Record |> scoped(scope) |> Repo.get(id) end)

  @doc "Fetches a session record by duck-typed session id to avoid coupling Records to Sessions."
  def get_record_for_session(%Scope{} = scope, %{id: session_id}),
    do:
      transact_tenant(scope, fn ->
        Record |> scoped(scope) |> Repo.get_by(session_id: session_id)
      end)

  @doc "Lists the owned patient's record history, newest first."
  def list_records(%Scope{} = scope, %{id: patient_id}) do
    transact_tenant(scope, fn ->
      Record
      |> scoped(scope)
      |> where([r], r.patient_id == ^patient_id)
      |> order_by([r], desc: r.inserted_at)
      |> Repo.all()
    end)
  end

  @doc """
  Lists the owned patient's latest `limit` done records, ordered by the session's
  clinical date descending instead of inserted_at, so an older session finalized later
  does not break clinical ordering. Filtering and ordering happen in the database.
  """
  def recent_done_records(%Scope{} = scope, %{id: patient_id}, limit \\ 3) do
    transact_tenant(scope, fn ->
      Record
      |> scoped(scope)
      |> join(:inner, [r], se in Session, on: se.id == r.session_id)
      |> where([r, se], r.patient_id == ^patient_id and r.generation_status == :done)
      |> order_by([r, se], desc: se.date)
      |> limit(^limit)
      |> select([r, se], r)
      |> Repo.all()
    end)
  end

  @doc "Updates content only when done. Does not trust the struct; reloads by scoped id."
  def update_record(%Scope{} = scope, %{id: id}, attrs) do
    with_owned(scope, id, fn
      %Record{generation_status: :done} = r ->
        r |> Record.content_changeset(attrs) |> Repo.update()

      %Record{} ->
        {:error, :not_editable}
    end)
  end

  def mark_reviewed(%Scope{} = scope, %{id: id}) do
    with_owned(scope, id, fn r ->
      r |> Record.content_changeset(%{content: r.content, reviewed: true}) |> Repo.update()
    end)
  end

  def retry_generation(%Scope{} = scope, %{id: id}) do
    with_owned(scope, id, fn
      %Record{generation_status: :error} = r ->
        r
        |> Record.status_changeset(%{generation_status: :pending, error_reason: nil})
        |> Repo.update!()
        |> tap(fn rec -> Oban.insert!(GenerateSoapWorker.new(job_args(rec))) end)
        |> then(&{:ok, &1})

      %Record{} ->
        {:error, :not_retryable}
    end)
  end

  # --- internals (worker, rebuilt scope): also reload and do not trust structs ---
  def mark_generating(%Scope{} = scope, %{id: id}),
    do: set_status(scope, id, %{generation_status: :generating})

  def complete(%Scope{} = scope, %{id: id}, content, model_used),
    do:
      set_status(scope, id, %{generation_status: :done, content: content, model_used: model_used})

  def fail(%Scope{} = scope, %{id: id}, reason),
    do: set_status(scope, id, %{generation_status: :error, error_reason: inspect(reason)})

  defp set_status(scope, id, changes) do
    res =
      with_owned(scope, id, fn r -> r |> Record.status_changeset(changes) |> Repo.update() end)

    with {:ok, r} <- res, do: broadcast(r)
    res
  end

  @doc "Lists the owner's done but unreviewed records across patients, newest first, scoped and preloading :patient."
  def list_pending_review(%Scope{} = scope, limit \\ 5) do
    transact_tenant(scope, fn ->
      Record
      |> scoped(scope)
      |> where([r], r.generation_status == :done and r.reviewed == false)
      |> order_by([r], desc: r.inserted_at)
      |> limit(^limit)
      |> preload(:patient)
      |> Repo.all()
    end)
  end

  @doc "Counts the owner's done but unreviewed records."
  def count_pending_review(%Scope{} = scope) do
    transact_tenant(scope, fn ->
      Record
      |> scoped(scope)
      |> where([r], r.generation_status == :done and r.reviewed == false)
      |> Repo.aggregate(:count)
    end)
  end

  # Reloads the record through a scoped query (tenant_id + user_id), then calls `fun`.
  defp with_owned(scope, id, fun) do
    transact_tenant(scope, fn ->
      case Record |> scoped(scope) |> Repo.get(id) do
        nil -> {:error, :unauthorized}
        record -> fun.(record)
      end
    end)
  end

  # --- pubsub ---
  def subscribe(record_id), do: Phoenix.PubSub.subscribe(@pubsub, "record:#{record_id}")

  def broadcast(%Record{} = r),
    do: Phoenix.PubSub.broadcast(@pubsub, "record:#{r.id}", {:record_updated, r})

  def job_args(%Record{} = r), do: %{record_id: r.id, user_id: r.user_id, tenant_id: r.tenant_id}

  defp scoped(query, scope),
    do: from(r in query, where: r.tenant_id == ^scope.tenant.id and r.user_id == ^scope.user.id)

  defdelegate transact_tenant(scope, fun), to: Repo
end
