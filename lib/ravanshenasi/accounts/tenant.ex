defmodule Ravanshenasi.Accounts.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenants" do
    field :name, :string
    field :plan, Ecto.Enum, values: [:solo, :clinic]

    has_many :users, Ravanshenasi.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :plan])
    |> validate_required([:name, :plan])
  end
end
