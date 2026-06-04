defmodule Ravanshenasi.AI.Client do
  @moduledoc "OpenAI-protocol chat client. Implementations talk to any compatible endpoint."
  @callback chat(provider_cfg :: map(), messages :: [map()], opts :: keyword()) ::
              {:ok, content :: String.t()} | {:error, reason :: term()}
end
