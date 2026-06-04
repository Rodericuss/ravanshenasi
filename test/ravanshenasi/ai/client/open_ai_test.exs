defmodule Ravanshenasi.AI.Client.OpenAITest do
  use ExUnit.Case, async: true

  alias Ravanshenasi.AI.Client.OpenAI

  test "POSTa chat/completions e extrai choices[0].message.content" do
    Req.Test.stub(OpenAI, fn conn ->
      assert conn.method == "POST"
      assert String.ends_with?(conn.request_path, "/chat/completions")
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "SOAP gerado"}}]})
    end)

    cfg = %{base_url: "https://api.example.com/v1", api_key: "sk-test", model: "gpt-x"}
    assert {:ok, "SOAP gerado"} = OpenAI.chat(cfg, [%{role: "user", content: "oi"}], [])
  end

  test "HTTP 500 → {:error, _}" do
    Req.Test.stub(OpenAI, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    cfg = %{base_url: "https://api.example.com/v1", api_key: "sk", model: "m"}
    assert {:error, _} = OpenAI.chat(cfg, [], [])
  end

  test "200 com content vazio → {:error, _}" do
    Req.Test.stub(OpenAI, fn conn ->
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => ""}}]})
    end)

    cfg = %{base_url: "https://api.example.com/v1", api_key: "sk", model: "m"}
    assert {:error, _} = OpenAI.chat(cfg, [], [])
  end
end
