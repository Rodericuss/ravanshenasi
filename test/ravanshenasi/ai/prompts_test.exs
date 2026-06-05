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

  test "suggestions_messages monta system+user com frameworks e pede JSON" do
    input = %{
      patient: %{
        name: "Ana",
        birth_date: ~D[1990-01-01],
        chief_complaint: "ansiedade",
        relevant_history: "—"
      },
      frameworks: [%{name: "TCC", description: "cognitivo-comportamental"}],
      recent_records: [
        %{content: "S:..\nO:..\nA:..\nP:..", inserted_at: ~U[2026-06-01 10:00:00Z]}
      ]
    }

    assert [%{role: "system", content: sys}, %{role: "user", content: user}] =
             Prompts.suggestions_messages(input)

    assert sys =~ "abordagens terapêuticas listadas"
    assert user =~ "TCC"
    assert user =~ "ansiedade"
    assert user =~ "JSON"
  end

  test "whatsapp_reply_messages varia o system por tom e inclui a transcrição" do
    base = %{
      patient: %{name: "Ana", chief_complaint: "ansiedade"},
      last_record: %{content: "S: ...\nP: ..."},
      transcription: "não tô conseguindo dormir",
      tone: :empathetic
    }

    assert [%{role: "system", content: sys}, %{role: "user", content: user}] =
             Prompts.whatsapp_reply_messages(base)

    assert sys =~ "empático"
    assert user =~ "não tô conseguindo dormir"
    assert user =~ "ansiedade"

    [%{content: enc_sys} | _] = Prompts.whatsapp_reply_messages(%{base | tone: :encouraging})
    assert enc_sys =~ "encorajador"
  end

  test "whatsapp_reply_messages tolera last_record nil" do
    msgs =
      Prompts.whatsapp_reply_messages(%{
        patient: %{name: "Ana", chief_complaint: "x"},
        last_record: nil,
        transcription: "oi",
        tone: :informative
      })

    [_sys, %{content: user}] = msgs
    assert user =~ "nenhuma registrada"
  end
end
