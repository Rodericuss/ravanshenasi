defmodule Ravanshenasi.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def change do
    create table(:invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :email, :citext, null: false
      add :role, :string, null: false
      add :token, :binary, null: false
      add :invited_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :accepted_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:tenant_id, :email])
    create unique_index(:invitations, [:token])
    create index(:invitations, [:tenant_id])
  end
end
