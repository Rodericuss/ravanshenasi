defmodule Ravanshenasi.Records do
  @moduledoc "SOAP records, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Records.GenerateSoapWorker
  alias Ravanshenasi.Records.Record
  alias Ravanshenasi.Repo

  @pubsub Ravanshenasi.PubSub

  def get_record(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> Record |> scoped(scope) |> Repo.get(id) end)

  @doc "Record da sessão (duck-typed por id pra não acoplar Records→Sessions)."
  def get_record_for_session(%Scope{} = scope, %{id: session_id}),
    do:
      transact_tenant(scope, fn ->
        Record |> scoped(scope) |> Repo.get_by(session_id: session_id)
      end)

  @doc "Edita o conteúdo (só quando :done). NÃO confia no struct — recarrega escopado por id."
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

  # --- internas (worker, scope reconstruído) — também recarregam, não confiam no struct ---
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

  # Recarrega o record por query escopada (tenant_id + user_id) e chama `fun`.
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
