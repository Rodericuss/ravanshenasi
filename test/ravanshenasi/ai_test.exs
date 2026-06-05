defmodule Ravanshenasi.AITest do
  use ExUnit.Case, async: false

  alias Ravanshenasi.AI
  alias Ravanshenasi.AI.Client.Stub

  defp input do
    %{
      patient: %{name: "X", birth_date: nil, chief_complaint: "c", relevant_history: "h"},
      frameworks: [],
      previous_sessions: [],
      current_notes: "n"
    }
  end

  setup do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)
  end

  test "usa o primeiro provider que responde :ok" do
    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad, :good],
      providers: %{
        bad: %{client: Stub, behavior: :error, model: "bad"},
        good: %{client: Stub, behavior: :ok, content: "SOAP OK", model: "good"}
      }
    )

    assert {:ok, %{content: "SOAP OK", provider: :good, model: "good"}} =
             AI.generate_soap(input())
  end

  test "todos falham → {:error, {:all_providers_failed, _}}" do
    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad],
      providers: %{bad: %{client: Stub, behavior: :error, model: "bad"}}
    )

    assert {:error, {:all_providers_failed, _}} = AI.generate_soap(input())
  end

  test "pula provider sem config (base_url/api_key/model nil)" do
    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:unconfigured, :good],
      providers: %{
        unconfigured: %{
          client: Ravanshenasi.AI.Client.OpenAI,
          base_url: nil,
          api_key: nil,
          model: nil
        },
        good: %{client: Stub, behavior: :ok, content: "OK", model: "good"}
      }
    )

    assert {:ok, %{provider: :good}} = AI.generate_soap(input())
  end

  test "chat/1 tenta providers na ordem e devolve o primeiro ok" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad, :good],
      providers: %{
        bad: %{client: Ravanshenasi.AI.Client.Stub, behavior: :error, model: "bad"},
        good: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: "OI", model: "good"}
      }
    )

    assert {:ok, %{content: "OI", provider: :good, model: "good"}} =
             Ravanshenasi.AI.chat([%{role: "user", content: "x"}])
  end

  test "generate_suggestions/1 com JSON válido do provider → {:ok, %{suggestions}}" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    json =
      ~s([{"framework":"TCC","justification":"j","techniques":["t"],"watch_out":"w"},
          {"framework":"ACT","justification":"j2","techniques":["t2"],"watch_out":"w2"}])

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:good],
      providers: %{
        good: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: json, model: "good"}
      }
    )

    input = %{
      patient: %{name: "Ana", birth_date: nil, chief_complaint: "x", relevant_history: "y"},
      frameworks: [%{name: "TCC", description: "d"}],
      recent_records: []
    }

    assert {:ok, %{suggestions: [s1, _s2], provider: :good, model: "good"}} =
             Ravanshenasi.AI.generate_suggestions(input)

    assert s1.framework == "TCC"
  end

  test "generate_suggestions/1 com JSON inválido → {:error, :invalid_json}" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:good],
      providers: %{
        good: %{
          client: Ravanshenasi.AI.Client.Stub,
          behavior: :ok,
          content: "sem json",
          model: "good"
        }
      }
    )

    input = %{
      patient: %{name: "Ana", birth_date: nil, chief_complaint: "x", relevant_history: "y"},
      frameworks: [],
      recent_records: []
    }

    assert {:error, :invalid_json} = Ravanshenasi.AI.generate_suggestions(input)
  end

  test "transcribe/1 tenta os providers em ordem e devolve %{text, provider, model}" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      transcription: %{
        order: [:bad, :good],
        providers: %{
          bad: %{client: Ravanshenasi.AI.Transcriber.Stub, behavior: :error, model: "bad"},
          good: %{
            client: Ravanshenasi.AI.Transcriber.Stub,
            behavior: :ok,
            text: "TX",
            model: "whisper-1"
          }
        }
      }
    )

    assert {:ok, %{text: "TX", provider: :good, model: "whisper-1"}} =
             Ravanshenasi.AI.transcribe("/qualquer.ogg")
  end

  test "transcribe/1 — todos falham → {:error, {:all_providers_failed, _}}" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      transcription: %{
        order: [:bad],
        providers: %{
          bad: %{client: Ravanshenasi.AI.Transcriber.Stub, behavior: :error, model: "bad"}
        }
      }
    )

    assert {:error, {:all_providers_failed, _}} = Ravanshenasi.AI.transcribe("/qualquer.ogg")
  end

  test "generate_reply/1 monta as mensagens e chama o chat" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:good],
      providers: %{
        good: %{
          client: Ravanshenasi.AI.Client.Stub,
          behavior: :ok,
          content: "Oi! Estou aqui.",
          model: "good"
        }
      }
    )

    input = %{
      patient: %{name: "Ana", chief_complaint: "x"},
      last_record: nil,
      transcription: "oi",
      tone: :empathetic
    }

    assert {:ok, %{content: "Oi! Estou aqui.", provider: :good, model: "good"}} =
             Ravanshenasi.AI.generate_reply(input)
  end
end
