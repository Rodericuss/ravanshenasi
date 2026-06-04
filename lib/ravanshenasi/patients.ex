defmodule Ravanshenasi.Patients do
  @moduledoc "Patient records, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Frameworks.ThinkingFramework
  alias Ravanshenasi.Patients.Patient
  alias Ravanshenasi.Patients.PatientFramework
  alias Ravanshenasi.Repo

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

  @doc "Active frameworks of a patient (presence in the join = active)."
  def list_patient_frameworks(%Scope{} = scope, %Patient{} = patient) do
    transact_tenant(scope, fn ->
      Repo.all(
        from f in ThinkingFramework,
          join: pf in PatientFramework,
          on: pf.thinking_framework_id == f.id,
          where: pf.patient_id == ^patient.id,
          order_by: [asc: f.name]
      )
    end)
  end

  @doc """
  Activates a framework on a patient. Validates ownership and framework visibility.

  Idempotent: re-activating an already-active framework is a no-op that still returns `:ok`.
  Returns `{:error, :unauthorized}` or `{:error, :not_found}` on access violations.
  """
  def activate_framework(%Scope{} = scope, %Patient{} = patient, %ThinkingFramework{} = framework) do
    cond do
      not owns?(scope, patient) ->
        {:error, :unauthorized}

      not visible?(scope, framework) ->
        {:error, :not_found}

      true ->
        transact_tenant(scope, fn ->
          %PatientFramework{tenant_id: scope.tenant.id}
          |> PatientFramework.changeset(%{
            patient_id: patient.id,
            thinking_framework_id: framework.id
          })
          |> Repo.insert(
            on_conflict: :nothing,
            conflict_target: [:patient_id, :thinking_framework_id]
          )
        end)

        :ok
    end
  end

  @doc "Deactivates a framework on a patient (removes from the join)."
  def deactivate_framework(
        %Scope{} = scope,
        %Patient{} = patient,
        %ThinkingFramework{} = framework
      ) do
    if owns?(scope, patient) do
      transact_tenant(scope, fn ->
        Repo.delete_all(
          from pf in PatientFramework,
            where: pf.patient_id == ^patient.id and pf.thinking_framework_id == ^framework.id
        )
      end)

      :ok
    else
      {:error, :unauthorized}
    end
  end

  # Visible = tenant catalog (user_id NULL) or owned by the scope's user.
  defp visible?(_scope, %ThinkingFramework{user_id: nil}), do: true
  defp visible?(scope, %ThinkingFramework{user_id: uid}), do: scope.user.id == uid

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
