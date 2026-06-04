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

  defp age(nil), do: "não informada"
  defp age(%Date{} = d), do: "#{div(Date.diff(Date.utc_today(), d), 365)} anos"

  defp frameworks_block([]), do: "- (nenhuma configurada)"
  defp frameworks_block(fws), do: Enum.map_join(fws, "\n", &"- #{&1.name}: #{&1.description}")

  defp previous_block([]), do: "- (nenhuma sessão anterior)"

  defp previous_block(prev),
    do: Enum.map_join(prev, "\n", &"- #{DateTime.to_date(&1.date)}: #{&1.notes}")
end
