defmodule Ravanshenasi.AI.Transcriber.OpenAI do
  @moduledoc "OpenAI-protocol speech-to-text (OpenAI Whisper, NVIDIA NIM ASR, any compatible /audio/transcriptions endpoint)."
  @behaviour Ravanshenasi.AI.Transcriber

  @impl true
  def transcribe(cfg, audio_path, _opts) do
    with {:ok, binary} <- read_audio(audio_path) do
      req =
        Req.new(
          base_url: cfg.base_url,
          auth: {:bearer, cfg.api_key},
          receive_timeout: 120_000,
          plug: Application.get_env(:ravanshenasi, :transcriber_req_plug)
        )

      form = [
        file:
          {binary, filename: Path.basename(audio_path), content_type: content_type(audio_path)},
        model: cfg.model,
        language: "pt"
      ]

      Req.post(req, url: "/audio/transcriptions", form_multipart: form)
      |> handle_transcription_response()
    end
  end

  defp handle_transcription_response({:ok, %{status: 200, body: %{"text" => t}}})
       when is_binary(t) do
    if String.trim(t) == "", do: {:error, {:empty_transcription, t}}, else: {:ok, t}
  end

  defp handle_transcription_response({:ok, %{status: 200, body: body}}),
    do: {:error, {:empty_transcription, body}}

  defp handle_transcription_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_transcription_response({:error, reason}),
    do: {:error, reason}

  # File.read/1 (não File.read!): arquivo sumido/ilegível vira erro controlado, nunca levanta.
  defp read_audio(path) do
    case File.read(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, posix} -> {:error, {:audio_unreadable, posix}}
    end
  end

  defp content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".ogg" -> "audio/ogg"
      ".mp3" -> "audio/mpeg"
      ".m4a" -> "audio/mp4"
      ".wav" -> "audio/wav"
      _ -> "application/octet-stream"
    end
  end
end
