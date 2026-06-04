defmodule Ravanshenasi.AI.Client.OpenAI do
  @moduledoc "OpenAI-protocol chat client (OpenAI, NVIDIA NIM, any compatible endpoint)."
  @behaviour Ravanshenasi.AI.Client

  @impl true
  def chat(cfg, messages, _opts) do
    req =
      Req.new(
        base_url: cfg.base_url,
        auth: {:bearer, cfg.api_key},
        receive_timeout: 60_000,
        plug: Application.get_env(:ravanshenasi, :ai_req_plug)
      )

    body = %{model: cfg.model, messages: messages, temperature: 0.3}

    case Req.post(req, url: "/chat/completions", json: body) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}}
      when is_binary(content) and content != "" ->
        {:ok, content}

      {:ok, %{status: 200} = resp} ->
        {:error, {:empty_content, resp.body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
