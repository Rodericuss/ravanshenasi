defmodule Ravanshenasi.AI.Transcriber.OpenAITest do
  use ExUnit.Case, async: true
  alias Ravanshenasi.AI.Transcriber.OpenAI

  @cfg %{base_url: "https://api.example.com/v1", api_key: "sk-test", model: "whisper-1"}

  setup do
    path = Path.join(System.tmp_dir!(), "t_#{System.unique_integer([:positive])}.ogg")
    File.write!(path, "fake-audio-bytes")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "POSTa /audio/transcriptions e extrai text", %{path: path} do
    Req.Test.stub(OpenAI, fn conn ->
      assert conn.method == "POST"
      assert String.ends_with?(conn.request_path, "/audio/transcriptions")
      Req.Test.json(conn, %{"text" => "olá, tudo bem?"})
    end)

    assert {:ok, "olá, tudo bem?"} = OpenAI.transcribe(@cfg, path, [])
  end

  test "texto vazio → {:error, {:empty_transcription, _}}", %{path: path} do
    Req.Test.stub(OpenAI, fn conn -> Req.Test.json(conn, %{"text" => "   "}) end)
    assert {:error, {:empty_transcription, _}} = OpenAI.transcribe(@cfg, path, [])
  end

  test "HTTP 500 → {:error, {:http_error, 500, _}}", %{path: path} do
    Req.Test.stub(OpenAI, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, {:http_error, 500, _}} = OpenAI.transcribe(@cfg, path, [])
  end

  test "arquivo inexistente → {:error, {:audio_unreadable, _}} (não levanta)" do
    assert {:error, {:audio_unreadable, _}} = OpenAI.transcribe(@cfg, "/nao/existe.ogg", [])
  end
end
