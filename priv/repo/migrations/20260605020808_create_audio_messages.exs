defmodule Ravanshenasi.Repo.Migrations.CreateAudioMessages do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:audio_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :user_id,
          references(:users,
            type: :binary_id,
            with: [tenant_id: :tenant_id],
            on_delete: :restrict
          ),
          null: false

      # 3-column composite FK via raw SQL (references/with: only does 2 cols). Ties patient↔owner.
      add :patient_id, :binary_id, null: false

      add :original_filename, :string, null: false
      add :tone, :string, null: false
      add :transcription, :text
      add :suggested_response, :text
      add :status, :string, null: false, default: "pending"
      add :transcription_model, :string
      add :reply_model_used, :string
      add :error_reason, :string

      timestamps(type: :utc_datetime)
    end

    execute(
      "ALTER TABLE audio_messages ADD CONSTRAINT audio_messages_patient_owner_fkey FOREIGN KEY (patient_id, tenant_id, user_id) REFERENCES patients (id, tenant_id, user_id) ON DELETE CASCADE",
      "ALTER TABLE audio_messages DROP CONSTRAINT audio_messages_patient_owner_fkey"
    )

    create index(:audio_messages, [:tenant_id, :user_id])
    create index(:audio_messages, [:tenant_id, :patient_id])
    create unique_index(:audio_messages, [:id, :tenant_id, :user_id])

    enable_tenant_rls("audio_messages")
  end
end
