defmodule Ravanshenasi.AI.Transcriber.StubTest do
  use ExUnit.Case, async: true
  alias Ravanshenasi.AI.Transcriber.Stub

  test "ok devolve o text configurado" do
    assert {:ok, "olá"} = Stub.transcribe(%{behavior: :ok, text: "olá"}, "/x.ogg", [])
  end

  test "default (sem behavior) devolve text padrão" do
    assert {:ok, "transcrição stub"} = Stub.transcribe(%{}, "/x.ogg", [])
  end

  test "error devolve o erro configurado" do
    assert {:error, :boom} = Stub.transcribe(%{behavior: :error, error: :boom}, "/x.ogg", [])
  end
end
