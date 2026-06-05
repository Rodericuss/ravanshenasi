defmodule Ravanshenasi.AI.SuggestionsTest do
  use ExUnit.Case, async: true
  alias Ravanshenasi.AI.Suggestions

  @valid ~s([{"framework":"TCC","justification":"j1","techniques":["t1","t2"],"watch_out":"w1"},
             {"framework":"ACT","justification":"j2","techniques":["t3"],"watch_out":"w2"}])

  test "JSON válido (2 itens) → structs normalizados" do
    assert {:ok, [a, b]} = Suggestions.parse(@valid)

    assert a == %{
             framework: "TCC",
             justification: "j1",
             techniques: ["t1", "t2"],
             watch_out: "w1"
           }

    assert b.framework == "ACT"
  end

  test "tolera texto antes e depois do array" do
    blob = "Claro! Aqui estão:\n" <> @valid <> "\nEspero ter ajudado."
    assert {:ok, [_, _]} = Suggestions.parse(blob)
  end

  test "tolera prosa multibyte (UTF-8) antes do array" do
    blob = "Análise concluída ✅ — sugestões:\n" <> @valid
    assert {:ok, [_, _]} = Suggestions.parse(blob)
  end

  test "JSON malformado → {:error, :invalid_json}" do
    assert {:error, :invalid_json} = Suggestions.parse("não tem json aqui")
    assert {:error, :invalid_json} = Suggestions.parse(~s([{"framework": "x" ]))
  end

  test "fora do range (0, 1 ou >4 itens) → {:error, :invalid_json}" do
    one = ~s([{"framework":"x","justification":"j","techniques":[],"watch_out":"w"}])
    assert {:error, :invalid_json} = Suggestions.parse("[]")
    assert {:error, :invalid_json} = Suggestions.parse(one)
  end

  test "item sem alguma chave obrigatória → {:error, :invalid_json}" do
    bad = ~s([{"framework":"a","justification":"j","techniques":["t"]},
              {"framework":"b","justification":"j","techniques":["t"],"watch_out":"w"}])
    assert {:error, :invalid_json} = Suggestions.parse(bad)
  end
end
