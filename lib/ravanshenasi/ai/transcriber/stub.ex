defmodule Ravanshenasi.AI.Transcriber.Stub do
  @moduledoc "Deterministic test transcriber — no network. Behavior driven by provider cfg."
  @behaviour Ravanshenasi.AI.Transcriber

  @impl true
  def transcribe(cfg, _audio_path, _opts) do
    case Map.get(cfg, :behavior, :ok) do
      :error -> {:error, Map.get(cfg, :error, :stub_error)}
      _ -> {:ok, Map.get(cfg, :text, "transcrição stub")}
    end
  end
end
