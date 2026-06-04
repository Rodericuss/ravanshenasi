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
end
