defmodule Ravanshenasi.Frameworks.ThinkingFramework do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "thinking_frameworks" do
    field :name, :string
    field :description, :string
    field :is_predefined, :boolean, default: false

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "User-facing changeset (create/edit name + description)."
  def changeset(framework, attrs) do
    framework
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name, name: :thinking_frameworks_tenant_user_name_index)
  end
end
