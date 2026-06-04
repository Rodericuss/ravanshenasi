defmodule Ravanshenasi.Frameworks.Defaults do
  @moduledoc "The 7 predefined therapeutic lines seeded per tenant."

  @frameworks [
    %{name: "TCC", description: "Terapia Cognitivo-Comportamental: identifica e reestrutura pensamentos e crenças disfuncionais; foco no presente, psicoeducação e tarefas entre sessões."},
    %{name: "Psicanálise", description: "Explora o inconsciente, conflitos internos, transferência e história infantil; associação livre e interpretação."},
    %{name: "Psicologia Analítica", description: "Abordagem junguiana: self, arquétipos, inconsciente coletivo, processo de individuação, símbolos e sonhos."},
    %{name: "Gestalt-terapia", description: "Awareness no aqui-e-agora, contato, responsabilidade e experimentos vivenciais; foco no processo."},
    %{name: "ACT", description: "Terapia de Aceitação e Compromisso: aceitação, desfusão cognitiva, valores e ação comprometida; flexibilidade psicológica."},
    %{name: "DBT", description: "Terapia Comportamental Dialética: regulação emocional, tolerância ao mal-estar, mindfulness e efetividade interpessoal."},
    %{name: "Humanista", description: "Abordagem centrada na pessoa: empatia, aceitação positiva incondicional e congruência; confia na tendência atualizante."}
  ]

  def all, do: @frameworks
end
