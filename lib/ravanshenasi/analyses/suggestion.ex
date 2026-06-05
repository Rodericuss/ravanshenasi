defmodule Ravanshenasi.Analyses.Suggestion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "suggestions" do
    field :framework_name, :string
    field :justification, :string
    field :techniques, {:array, :string}, default: []
    field :watch_out, :string
    field :status, Ecto.Enum, values: [:suggested, :saved, :discarded], default: :suggested

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User
    belongs_to :analysis, Ravanshenasi.Analyses.Analysis

    timestamps(type: :utc_datetime)
  end

  @doc "Insert changeset. tenant_id/user_id are DERIVED from the analysis, never the caller."
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :analysis_id,
      :framework_name,
      :justification,
      :techniques,
      :watch_out,
      :status
    ])
    |> validate_required([:tenant_id, :user_id, :analysis_id, :framework_name])
  end

  @doc "Save/discard a card."
  def status_changeset(suggestion, attrs), do: cast(suggestion, attrs, [:status])
end
