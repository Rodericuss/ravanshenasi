defmodule Ravanshenasi.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  def change do
    create table(:tenants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :plan, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
