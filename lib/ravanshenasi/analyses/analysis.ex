defmodule Ravanshenasi.Analyses.Analysis do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "analyses" do
    field :generation_status, Ecto.Enum,
      values: [:pending, :generating, :done, :error],
      default: :pending

    field :model_used, :string
    field :error_reason, :string

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User
    belongs_to :patient, Ravanshenasi.Patients.Patient
    has_many :suggestions, Ravanshenasi.Analyses.Suggestion

    timestamps(type: :utc_datetime)
  end

  @doc """
  Insert changeset for a new (pending) analysis. Declares the partial unique index
  so a concurrent double-click returns {:error, changeset} instead of raising
  Ecto.ConstraintError — the context catches it and returns the active analysis.
  """
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:tenant_id, :user_id, :patient_id])
    |> validate_required([:tenant_id, :user_id, :patient_id])
    |> unique_constraint([:tenant_id, :user_id, :patient_id],
      name: :analyses_one_active_per_patient
    )
  end

  @doc "Status transitions (generating/done/error)."
  def status_changeset(analysis, attrs) do
    cast(analysis, attrs, [:generation_status, :model_used, :error_reason])
  end
end
