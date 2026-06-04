defmodule Ravanshenasi.AI.PromptsTest do
  use ExUnit.Case, async: true

  alias Ravanshenasi.AI.Prompts

  test "monta system + user com perfil, frameworks, sessões anteriores e notas atuais" do
    input = %{
      patient: %{
        name: "Maria",
        birth_date: ~D[1990-01-01],
        chief_complaint: "ansiedade",
        relevant_history: "—"
      },
      frameworks: [%{name: "TCC", description: "reestrutura pensamentos"}],
      previous_sessions: [%{date: ~U[2026-05-01 10:00:00Z], notes: "sessão anterior X"}],
      current_notes: "sessão de hoje Y"
    }

    assert [%{role: "system", content: sys}, %{role: "user", content: user}] =
             Prompts.soap_messages(input)

    assert sys =~ "SOAP"
    assert user =~ "Maria"
    assert user =~ "TCC"
    assert user =~ "sessão anterior X"
    assert user =~ "sessão de hoje Y"
  end
end
