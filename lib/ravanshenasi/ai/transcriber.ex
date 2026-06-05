defmodule Ravanshenasi.AI.Transcriber do
  @moduledoc "Speech-to-text protocol. Implementations talk to any OpenAI-compatible /audio/transcriptions endpoint."
  @callback transcribe(provider_cfg :: map(), audio_path :: String.t(), opts :: keyword()) ::
              {:ok, text :: String.t()} | {:error, reason :: term()}
end
