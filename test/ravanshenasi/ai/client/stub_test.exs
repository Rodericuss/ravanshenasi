defmodule Ravanshenasi.AI.Client.StubTest do
  use ExUnit.Case, async: true

  alias Ravanshenasi.AI.Client.Stub

  test ":ok devolve content" do
    assert {:ok, content} = Stub.chat(%{behavior: :ok}, [], [])
    assert is_binary(content) and content != ""
  end

  test ":error devolve erro" do
    assert {:error, :stub_error} = Stub.chat(%{behavior: :error}, [], [])
  end
end
