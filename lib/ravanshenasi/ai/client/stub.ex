defmodule Ravanshenasi.AI.Client.Stub do
  @moduledoc "Deterministic test client — no network. Behavior driven by provider cfg."
  @behaviour Ravanshenasi.AI.Client

  @impl true
  def chat(cfg, _messages, _opts) do
    case Map.get(cfg, :behavior, :ok) do
      :error -> {:error, Map.get(cfg, :error, :stub_error)}
      _ -> {:ok, Map.get(cfg, :content, "S: stub\nO: stub\nA: stub\nP: stub")}
    end
  end
end
