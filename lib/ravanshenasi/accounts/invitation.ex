defmodule Ravanshenasi.Accounts.Invitation do
  use Ecto.Schema
  import Ecto.Changeset

  @token_bytes 32
  @ttl_days 7

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "invitations" do
    field :email, :string
    field :role, Ecto.Enum, values: [:therapist]
    field :token, :binary
    field :accepted_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :invited_by_user, Ravanshenasi.Accounts.User, foreign_key: :invited_by_user_id

    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :role])
    |> validate_required([:email, :role])
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+$/)
  end

  @doc """
  Monta uma invitation com token. Retorna `{raw_token, changeset}` —
  o token cru vai no link do email; só o hash é persistido.
  """
  def build(attrs, opts) do
    raw_token = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
    hashed = :crypto.hash(:sha256, raw_token)
    expires_at = DateTime.utc_now() |> DateTime.add(@ttl_days, :day) |> DateTime.truncate(:second)

    changeset =
      %__MODULE__{}
      |> changeset(attrs)
      |> put_change(:token, hashed)
      |> put_change(:tenant_id, opts[:tenant_id])
      |> put_change(:invited_by_user_id, opts[:invited_by_user_id])
      |> put_change(:expires_at, expires_at)

    {raw_token, changeset}
  end

  @doc "Hash de um token cru, pra lookup."
  def hash_token(raw_token), do: :crypto.hash(:sha256, raw_token)
end
