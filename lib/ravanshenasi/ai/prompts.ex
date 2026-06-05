defmodule Ravanshenasi.AI.Prompts do
  @moduledoc "Builds the SOAP chat messages (OpenAI format) from clinical context."

  @system """
  Você é um assistente clínico especializado em psicologia. Gera prontuários clínicos \
  estruturados no formato SOAP (Subjetivo, Objetivo, Avaliação, Plano) a partir das notas \
  de sessão. Use linguagem clínica e de hipótese ("sugere", "indica", "observa-se"); \
  nunca faça diagnósticos definitivos e nunca invente informação fora das notas. \
  Responda apenas com o prontuário, sem introdução ou conclusão.
  """

  @spec soap_messages(map()) :: [map()]
  def soap_messages(%{patient: p, frameworks: fws, previous_sessions: prev, current_notes: notes}) do
    [
      %{role: "system", content: String.trim(@system)},
      %{role: "user", content: user_content(p, fws, prev, notes)}
    ]
  end

  defp user_content(p, fws, prev, notes) do
    """
    Perfil do paciente:
    - Nome: #{p.name}
    - Idade: #{age(p.birth_date)}
    - Queixa principal: #{p.chief_complaint}
    - Histórico relevante: #{p.relevant_history}

    Linhas de pensamento ativas:
    #{frameworks_block(fws)}

    Sessões anteriores (mais recentes):
    #{previous_block(prev)}

    Notas da sessão atual:
    #{notes}

    Gere o prontuário no formato SOAP (S/O/A/P).
    """
  end

  @suggestions_system """
  Você é um supervisor clínico em psicologia com amplo conhecimento em múltiplas \
  abordagens terapêuticas. Sua função é analisar o perfil de um paciente e sugerir \
  vertentes de abordagem para o próximo atendimento. Baseie suas sugestões \
  exclusivamente nas abordagens terapêuticas listadas pelo terapeuta. Seja específico, \
  clínico e justifique cada sugestão com base no perfil do paciente.
  """

  @spec suggestions_messages(map()) :: [map()]
  def suggestions_messages(%{patient: p, frameworks: fws, recent_records: recs}) do
    [
      %{role: "system", content: String.trim(@suggestions_system)},
      %{role: "user", content: suggestions_user(p, fws, recs)}
    ]
  end

  defp suggestions_user(p, fws, recs) do
    """
    Abordagens terapêuticas que o terapeuta utiliza:
    #{frameworks_block(fws)}

    Perfil do paciente:
    - Nome: #{p.name} | Idade: #{age(p.birth_date)}
    - Queixa principal: #{p.chief_complaint}
    - Histórico: #{p.relevant_history}

    Histórico de sessões e prontuários recentes:
    #{records_block(recs)}

    Gere entre 2 e 4 sugestões de abordagem para o próximo atendimento.
    Responda APENAS em JSON, um array no formato:
    [
      {"framework": "nome da abordagem", "justification": "por quê para este paciente",
       "techniques": ["técnica 1", "técnica 2"], "watch_out": "pontos de atenção/riscos"}
    ]
    """
  end

  defp records_block([]), do: "- (nenhum prontuário recente)"
  defp records_block(recs), do: Enum.map_join(recs, "\n\n", & &1.content)

  defp age(nil), do: "não informada"
  defp age(%Date{} = d), do: "#{div(Date.diff(Date.utc_today(), d), 365)} anos"

  defp frameworks_block([]), do: "- (nenhuma configurada)"
  defp frameworks_block(fws), do: Enum.map_join(fws, "\n", &"- #{&1.name}: #{&1.description}")

  defp previous_block([]), do: "- (nenhuma sessão anterior)"

  defp previous_block(prev),
    do: Enum.map_join(prev, "\n", &"- #{DateTime.to_date(&1.date)}: #{&1.notes}")
end
