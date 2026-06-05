defmodule Ravanshenasi.AI do
  @moduledoc "Domain facade: builds chat messages and tries providers in order (fallback)."

  alias Ravanshenasi.AI.{Prompts, Suggestions}

  @type chat_ok :: %{content: String.t(), provider: atom(), model: String.t()}

  @spec chat([map()]) :: {:ok, chat_ok()} | {:error, {:all_providers_failed, list()}}
  def chat(messages) do
    cfg = Application.fetch_env!(:ravanshenasi, __MODULE__)
    try_providers(cfg[:order], cfg[:providers], messages, [])
  end

  @spec generate_soap(map()) :: {:ok, chat_ok()} | {:error, {:all_providers_failed, list()}}
  def generate_soap(input), do: chat(Prompts.soap_messages(input))

  @spec generate_suggestions(map()) ::
          {:ok, %{suggestions: [map()], provider: atom(), model: String.t()}}
          | {:error, {:all_providers_failed, list()} | :invalid_json}
  def generate_suggestions(input) do
    with {:ok, %{content: content, provider: provider, model: model}} <-
           chat(Prompts.suggestions_messages(input)),
         {:ok, suggestions} <- Suggestions.parse(content) do
      {:ok, %{suggestions: suggestions, provider: provider, model: model}}
    end
  end

  defp try_providers([], _providers, _messages, errors),
    do: {:error, {:all_providers_failed, Enum.reverse(errors)}}

  defp try_providers([name | rest], providers, messages, errors) do
    case Map.get(providers, name) do
      nil -> try_providers(rest, providers, messages, [{name, :unknown_provider} | errors])
      pcfg -> try_one(name, pcfg, rest, providers, messages, errors)
    end
  end

  defp try_one(name, pcfg, rest, providers, messages, errors) do
    if configured?(pcfg) do
      case pcfg.client.chat(pcfg, messages, []) do
        {:ok, content} when is_binary(content) and content != "" ->
          {:ok, %{content: content, provider: name, model: pcfg[:model]}}

        other ->
          try_providers(rest, providers, messages, [{name, other} | errors])
      end
    else
      try_providers(rest, providers, messages, [{name, :missing_config} | errors])
    end
  end

  # Stub não precisa de credenciais; clientes HTTP precisam de base_url + api_key + model.
  defp configured?(%{client: Ravanshenasi.AI.Client.Stub}), do: true

  defp configured?(%{base_url: b, api_key: k, model: m}),
    do: present?(b) and present?(k) and present?(m)

  defp configured?(_), do: false
  defp present?(v), do: v not in [nil, ""]
end
