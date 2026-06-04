defmodule Ravanshenasi.Repo.Migrations.SeedDefaultFrameworksBackfill do
  use Ecto.Migration

  # Frozen copy of the 7 defaults (a data migration must not depend on app code
  # that may change). Bypass is required: thinking_frameworks already has FORCE RLS.
  def up do
    execute("SET LOCAL app.auth_bypass = 'on'")

    execute("""
    INSERT INTO thinking_frameworks (id, tenant_id, user_id, name, description, is_predefined, inserted_at, updated_at)
    SELECT gen_random_uuid(), t.id, NULL, d.name, d.description, true, now(), now()
    FROM tenants t
    CROSS JOIN (VALUES
      ('TCC', 'Terapia Cognitivo-Comportamental: identifica e reestrutura pensamentos e crenças disfuncionais; foco no presente, psicoeducação e tarefas entre sessões.'),
      ('Psicanálise', 'Explora o inconsciente, conflitos internos, transferência e história infantil; associação livre e interpretação.'),
      ('Psicologia Analítica', 'Abordagem junguiana: self, arquétipos, inconsciente coletivo, processo de individuação, símbolos e sonhos.'),
      ('Gestalt-terapia', 'Awareness no aqui-e-agora, contato, responsabilidade e experimentos vivenciais; foco no processo.'),
      ('ACT', 'Terapia de Aceitação e Compromisso: aceitação, desfusão cognitiva, valores e ação comprometida; flexibilidade psicológica.'),
      ('DBT', 'Terapia Comportamental Dialética: regulação emocional, tolerância ao mal-estar, mindfulness e efetividade interpessoal.'),
      ('Humanista', 'Abordagem centrada na pessoa: empatia, aceitação positiva incondicional e congruência; confia na tendência atualizante.')
    ) AS d(name, description)
    WHERE NOT EXISTS (
      SELECT 1 FROM thinking_frameworks f WHERE f.tenant_id = t.id AND f.user_id IS NULL
    )
    """)
  end

  def down, do: :ok
end
