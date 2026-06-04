defmodule Ravanshenasi.Patients do
  @moduledoc "Patient records, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Repo
  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Patients.Patient

  @doc "Lists the scope's patients. opts: :status (filter), :q (name ilike)."
  def list_patients(%Scope{} = scope, opts \\ []) do
    transact_tenant(scope, fn ->
      Patient
      |> scoped(scope)
      |> filter_status(opts[:status])
      |> search_name(opts[:q])
      |> order_by([p], asc: p.name)
      |> Repo.all()
    end)
  end

  def get_patient(%Scope{} = scope, id) do
    transact_tenant(scope, fn -> Patient |> scoped(scope) |> Repo.get(id) end)
  end

  def get_patient!(%Scope{} = scope, id) do
    transact_tenant(scope, fn -> Patient |> scoped(scope) |> Repo.get!(id) end)
  end

  def create_patient(%Scope{} = scope, attrs) do
    if Scope.clinical_access?(scope) do
      transact_tenant(scope, fn ->
        %Patient{tenant_id: scope.tenant.id, user_id: scope.user.id}
        |> Patient.changeset(attrs)
        |> Repo.insert()
      end)
    else
      {:error, :unauthorized}
    end
  end

  def update_patient(%Scope{} = scope, %Patient{} = patient, attrs) do
    if owns?(scope, patient) do
      transact_tenant(scope, fn -> patient |> Patient.changeset(attrs) |> Repo.update() end)
    else
      {:error, :unauthorized}
    end
  end

  def inactivate_patient(%Scope{} = scope, %Patient{} = patient) do
    update_patient(scope, patient, %{status: :inactive})
  end

  def change_patient(%Patient{} = patient, attrs \\ %{}), do: Patient.changeset(patient, attrs)

  defp scoped(query, scope) do
    from p in query, where: p.tenant_id == ^scope.tenant.id and p.user_id == ^scope.user.id
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: from(p in query, where: p.status == ^status)

  defp search_name(query, nil), do: query
  defp search_name(query, ""), do: query
  defp search_name(query, q), do: from(p in query, where: ilike(p.name, ^"%#{q}%"))

  defp owns?(scope, %Patient{user_id: uid, tenant_id: tid}) do
    Scope.clinical_access?(scope) and scope.user.id == uid and scope.tenant.id == tid
  end

  defdelegate transact_tenant(scope, fun), to: Repo
end
