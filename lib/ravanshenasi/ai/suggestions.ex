defmodule Ravanshenasi.AI.Suggestions do
  @moduledoc """
  Tolerant parser for the LLM suggestions output. The model returns JSON possibly
  wrapped in prose; we extract from the first `[` to the last `]`, decode, and
  validate 2–4 items each carrying the 4 required keys.
  """

  @keys ~w(framework justification techniques watch_out)

  @spec parse(String.t()) :: {:ok, [map()]} | {:error, :invalid_json}
  def parse(content) when is_binary(content) do
    with {:ok, json} <- extract_array(content),
         {:ok, list} <- Jason.decode(json),
         true <- valid?(list) do
      {:ok, Enum.map(list, &normalize/1)}
    else
      _ -> {:error, :invalid_json}
    end
  end

  def parse(_), do: {:error, :invalid_json}

  # First "[" to last "]" by BYTE offset (binary_part), so multibyte UTF-8 prose
  # before the array doesn't shift the slice.
  defp extract_array(content) do
    with {start, _} <- :binary.match(content, "["),
         [_ | _] = closers <- :binary.matches(content, "]"),
         {stop, _} <- List.last(closers),
         true <- stop >= start do
      {:ok, binary_part(content, start, stop - start + 1)}
    else
      _ -> :error
    end
  end

  defp valid?(list) when is_list(list) and length(list) in 2..4,
    do: Enum.all?(list, &valid_item?/1)

  defp valid?(_), do: false

  defp valid_item?(%{} = m),
    do: Enum.all?(@keys, &Map.has_key?(m, &1)) and is_list(m["techniques"])

  defp valid_item?(_), do: false

  defp normalize(m) do
    %{
      framework: m["framework"],
      justification: m["justification"],
      techniques: m["techniques"],
      watch_out: m["watch_out"]
    }
  end
end
