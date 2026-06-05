# Fatia 4 — Áudio do WhatsApp (Whisper + Sugestão) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **WORKFLOW CONSTRAINT (deste projeto, não-negociável):** Trabalhar **direto na `main`**, **SEM branches**. **NÃO commitar** — o usuário faz os commits. Este plano **não tem passos de commit**: cada task termina com testes verdes e deixa a working tree pronta. NÃO rodar `git add`/`git commit`/`git push`. NÃO adicionar trailer `Co-Authored-By`/`Generated with`. Flag de teste verboso no Elixir 1.19 deste repo é `--trace` (NÃO `-v`).

**Goal:** Profissional faz upload de um áudio de paciente → Whisper transcreve → LLM sugere uma resposta (no tom escolhido) editável/copiável, tudo async e sem reter o áudio.

**Architecture:** Reusa Oban (`queue: :ai`), PubSub e o padrão scope/RLS das fatias 1–3. Acrescenta um behaviour novo `AI.Transcriber` (multipart, OpenAI/NIM-compatible, com `order`/`providers`/fallback simétrico ao chat), a tabela `audio_messages`, um worker de 2 etapas idempotente (transcrição → sugestão), e a `AudioLive` (upload). O binário é descartado assim que a transcrição é gravada.

**Tech Stack:** Elixir 1.19 / Phoenix 1.8.7 / LiveView 1.1 (uploads) / Ecto / Oban ~2.23 / `req` 0.5.18 (`form_multipart`) / Jason.

**Invariante crítico:** `Repo.transact_tenant/2` faz `SET LOCAL app.current_tenant_id = ''` no sucesso — **NÃO aninhar `transact_tenant`**. Dentro de um `transact_tenant`, consultar inline (`Repo.get`/`Repo.one`/`Repo.exists?`); fora de transação (worker sequencial) chamar contexts é OK.

---

## File Structure

| Arquivo | Responsabilidade |
|---|---|
| `lib/ravanshenasi/ai/transcriber.ex` | **Criar:** behaviour `transcribe/3`. |
| `lib/ravanshenasi/ai/transcriber/stub.ex` | **Criar:** transcriber determinístico (testes). |
| `lib/ravanshenasi/ai/transcriber/open_ai.ex` | **Criar:** multipart via `req` (`File.read`, rejeita vazio), OpenAI/NIM. |
| `lib/ravanshenasi/ai.ex` | **Modificar:** `transcribe/1` (order/providers/fallback) + `generate_reply/1`. |
| `lib/ravanshenasi/ai/prompts.ex` | **Modificar:** `whatsapp_reply_messages/1` (3 tons, `last_record` nil). |
| `lib/ravanshenasi/audio_messages/audio_message.ex` | **Criar:** schema + changesets. |
| `lib/ravanshenasi/audio_messages.ex` | **Criar:** context (create/get/list/update/retry + internos idempotentes + pubsub). |
| `lib/ravanshenasi/audio_messages/transcribe_and_suggest_worker.ex` | **Criar:** Oban worker 2 etapas. |
| `lib/ravanshenasi_web/live/audio_live/index.ex` | **Criar:** upload + lista + edição/cópia + retry + PubSub. |
| `lib/ravanshenasi_web/router.ex` | **Modificar:** rota no `live_session :require_clinical`. |
| `priv/repo/migrations/*_create_audio_messages.exs` | **Criar:** tabela + FK composta + RLS. |
| `config/{config,runtime,test}.exs` | **Modificar:** chave `transcription:` + `:transcriber_req_plug`. |

**Ordem:** T1–T5 (IA, sem DB) → T6–T7 (migration+schema) → T8–T10 (context) → T11 (worker) → T12–T13 (router+LiveView). Cada task é TDD.

---

## Task 1: `AI.Transcriber` behaviour + `Transcriber.Stub`

**Files:**
- Create: `lib/ravanshenasi/ai/transcriber.ex`
- Create: `lib/ravanshenasi/ai/transcriber/stub.ex`
- Test: `test/ravanshenasi/ai/transcriber/stub_test.exs`

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ravanshenasi/ai/transcriber/stub_test.exs`:
```elixir
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
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/ai/transcriber/stub_test.exs --trace`
Expected: FAIL — módulo `Ravanshenasi.AI.Transcriber.Stub` não existe.

- [ ] **Step 3: Implementar**

Criar `lib/ravanshenasi/ai/transcriber.ex`:
```elixir
defmodule Ravanshenasi.AI.Transcriber do
  @moduledoc "Speech-to-text protocol. Implementations talk to any OpenAI-compatible /audio/transcriptions endpoint."
  @callback transcribe(provider_cfg :: map(), audio_path :: String.t(), opts :: keyword()) ::
              {:ok, text :: String.t()} | {:error, reason :: term()}
end
```

Criar `lib/ravanshenasi/ai/transcriber/stub.ex`:
```elixir
defmodule Ravanshenasi.AI.Transcriber.Stub do
  @moduledoc "Deterministic test transcriber — no network. Behavior driven by provider cfg."
  @behaviour Ravanshenasi.AI.Transcriber

  @impl true
  def transcribe(cfg, _audio_path, _opts) do
    case Map.get(cfg, :behavior, :ok) do
      :error -> {:error, Map.get(cfg, :error, :stub_error)}
      _ -> {:ok, Map.get(cfg, :text, "transcrição stub")}
    end
  end
end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/ai/transcriber/stub_test.exs --trace`
Expected: PASS (3 testes).

---

## Task 2: `AI.Transcriber.OpenAI` (multipart)

**Files:**
- Create: `lib/ravanshenasi/ai/transcriber/open_ai.ex`
- Test: `test/ravanshenasi/ai/transcriber/open_ai_test.exs`
- Modify: `config/test.exs` (registrar `:transcriber_req_plug`)

`File.read/1` (nunca levanta), multipart via `req`, rejeita texto vazio. Espelha o `Client.OpenAI` (que serve OpenAI **e** NIM).

- [ ] **Step 1: Registrar o plug de teste**

Em `config/test.exs`, abaixo da linha `config :ravanshenasi, :ai_req_plug, {Req.Test, Ravanshenasi.AI.Client.OpenAI}`, acrescentar:
```elixir
config :ravanshenasi, :transcriber_req_plug, {Req.Test, Ravanshenasi.AI.Transcriber.OpenAI}
```

- [ ] **Step 2: Escrever o teste que falha**

Criar `test/ravanshenasi/ai/transcriber/open_ai_test.exs`:
```elixir
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
```

- [ ] **Step 3: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/ai/transcriber/open_ai_test.exs --trace`
Expected: FAIL — módulo `Ravanshenasi.AI.Transcriber.OpenAI` não existe.

- [ ] **Step 4: Implementar**

Criar `lib/ravanshenasi/ai/transcriber/open_ai.ex`:
```elixir
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
        file: {binary, filename: Path.basename(audio_path), content_type: content_type(audio_path)},
        model: cfg.model,
        language: "pt"
      ]

      case Req.post(req, url: "/audio/transcriptions", form_multipart: form) do
        {:ok, %{status: 200, body: %{"text" => t}}} when is_binary(t) ->
          if String.trim(t) == "", do: {:error, {:empty_transcription, t}}, else: {:ok, t}

        {:ok, %{status: 200, body: body}} ->
          {:error, {:empty_transcription, body}}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

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
```

- [ ] **Step 5: Rodar e ver passar**

Run: `mix test test/ravanshenasi/ai/transcriber/open_ai_test.exs --trace`
Expected: PASS (4 testes).

---

## Task 3: `AI.transcribe/1` (facade + config)

**Files:**
- Modify: `lib/ravanshenasi/ai.ex`
- Modify: `config/config.exs`, `config/runtime.exs`, `config/test.exs`
- Test: `test/ravanshenasi/ai_test.exs`

`order`/`providers`/fallback simétrico ao chat; retorna `%{text, provider, model}`.

- [ ] **Step 1: Config `transcription:` (default + runtime + stub de teste)**

Em `config/config.exs`, dentro do bloco `config :ravanshenasi, Ravanshenasi.AI,` (que hoje tem `order:` e `providers:`), acrescentar a chave `transcription:`:
```elixir
config :ravanshenasi, Ravanshenasi.AI,
  order: [:openai],
  providers: %{
    openai: %{client: Ravanshenasi.AI.Client.OpenAI, base_url: nil, api_key: nil, model: nil}
  },
  transcription: %{
    order: [:openai],
    providers: %{
      openai: %{client: Ravanshenasi.AI.Transcriber.OpenAI, base_url: nil, api_key: nil, model: nil}
    }
  }
```

Em `config/runtime.exs`, no bloco `config :ravanshenasi, Ravanshenasi.AI, order: ..., providers: ...`, acrescentar a chave `transcription:` (whitelist no env, nunca `String.to_atom`):
```elixir
    transcription: %{
      order:
        System.get_env("AI_TRANSCRIPTION_ORDER", "openai")
        |> String.split(",", trim: true)
        |> Enum.flat_map(fn name ->
          case String.trim(name) do
            "openai" -> [:openai]
            "nim" -> [:nim]
            _ -> []
          end
        end),
      providers: %{
        openai: %{
          client: Ravanshenasi.AI.Transcriber.OpenAI,
          base_url: System.get_env("OPENAI_BASE_URL", "https://api.openai.com/v1"),
          api_key: System.get_env("OPENAI_API_KEY"),
          model: System.get_env("OPENAI_TRANSCRIBE_MODEL", "whisper-1")
        },
        nim: %{
          client: Ravanshenasi.AI.Transcriber.OpenAI,
          base_url: System.get_env("NIM_ASR_BASE_URL"),
          api_key: System.get_env("NIM_API_KEY"),
          model: System.get_env("NIM_ASR_MODEL")
        }
      }
    }
```

Em `config/test.exs`, no bloco `config :ravanshenasi, Ravanshenasi.AI, order: [:stub], providers: ...`, acrescentar:
```elixir
  transcription: %{
    order: [:stub],
    providers: %{stub: %{client: Ravanshenasi.AI.Transcriber.Stub, text: "olá, tudo bem?"}}
  }
```
> Atenção: `config :app, Key, kw` substitui a key inteira. Acrescente `transcription:` **dentro** do mesmo `config :ravanshenasi, Ravanshenasi.AI, ...` de cada arquivo (não um `config` separado).

- [ ] **Step 2: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/ai_test.exs`:
```elixir
  test "transcribe/1 tenta os providers em ordem e devolve %{text, provider, model}" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      transcription: %{
        order: [:bad, :good],
        providers: %{
          bad: %{client: Ravanshenasi.AI.Transcriber.Stub, behavior: :error, model: "bad"},
          good: %{client: Ravanshenasi.AI.Transcriber.Stub, behavior: :ok, text: "TX", model: "whisper-1"}
        }
      }
    )

    assert {:ok, %{text: "TX", provider: :good, model: "whisper-1"}} =
             Ravanshenasi.AI.transcribe("/qualquer.ogg")
  end

  test "transcribe/1 — todos falham → {:error, {:all_providers_failed, _}}" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      transcription: %{
        order: [:bad],
        providers: %{bad: %{client: Ravanshenasi.AI.Transcriber.Stub, behavior: :error, model: "bad"}}
      }
    )

    assert {:error, {:all_providers_failed, _}} = Ravanshenasi.AI.transcribe("/qualquer.ogg")
  end
```

- [ ] **Step 3: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/ai_test.exs --trace`
Expected: FAIL — `function Ravanshenasi.AI.transcribe/1 is undefined`.

- [ ] **Step 4: Implementar**

Em `lib/ravanshenasi/ai.ex`, acrescentar (o `present?/1` já existe e é reusado):
```elixir
  @spec transcribe(String.t()) ::
          {:ok, %{text: String.t(), provider: atom(), model: String.t()}}
          | {:error, {:all_providers_failed, list()}}
  def transcribe(audio_path) do
    cfg = Application.fetch_env!(:ravanshenasi, __MODULE__)[:transcription]
    try_transcribers(cfg[:order], cfg[:providers], audio_path, [])
  end

  defp try_transcribers([], _providers, _path, errors),
    do: {:error, {:all_providers_failed, Enum.reverse(errors)}}

  defp try_transcribers([name | rest], providers, path, errors) do
    case Map.get(providers, name) do
      nil -> try_transcribers(rest, providers, path, [{name, :unknown_provider} | errors])
      pcfg -> try_one_transcriber(name, pcfg, rest, providers, path, errors)
    end
  end

  defp try_one_transcriber(name, pcfg, rest, providers, path, errors) do
    if transcriber_configured?(pcfg) do
      case pcfg.client.transcribe(pcfg, path, []) do
        {:ok, text} when is_binary(text) and text != "" ->
          {:ok, %{text: text, provider: name, model: pcfg[:model]}}

        other ->
          try_transcribers(rest, providers, path, [{name, other} | errors])
      end
    else
      try_transcribers(rest, providers, path, [{name, :missing_config} | errors])
    end
  end

  defp transcriber_configured?(%{client: Ravanshenasi.AI.Transcriber.Stub}), do: true

  defp transcriber_configured?(%{base_url: b, api_key: k, model: m}),
    do: present?(b) and present?(k) and present?(m)

  defp transcriber_configured?(_), do: false
```

- [ ] **Step 5: Rodar e ver passar**

Run: `mix test test/ravanshenasi/ai_test.exs --trace`
Expected: PASS (todos, incl. SOAP/suggestions antigos e os 2 novos).

---

## Task 4: `AI.Prompts.whatsapp_reply_messages/1`

**Files:**
- Modify: `lib/ravanshenasi/ai/prompts.ex`
- Test: `test/ravanshenasi/ai/prompts_test.exs`

3 tons (system varia), `last_record` pode ser `nil`.

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/ai/prompts_test.exs`:
```elixir
  test "whatsapp_reply_messages varia o system por tom e inclui a transcrição" do
    base = %{
      patient: %{name: "Ana", chief_complaint: "ansiedade"},
      last_record: %{content: "S: ...\nP: ..."},
      transcription: "não tô conseguindo dormir",
      tone: :empathetic
    }

    assert [%{role: "system", content: sys}, %{role: "user", content: user}] =
             Prompts.whatsapp_reply_messages(base)

    assert sys =~ "empático"
    assert user =~ "não tô conseguindo dormir"
    assert user =~ "ansiedade"

    [%{content: enc_sys} | _] = Prompts.whatsapp_reply_messages(%{base | tone: :encouraging})
    assert enc_sys =~ "encorajador"
  end

  test "whatsapp_reply_messages tolera last_record nil" do
    msgs =
      Prompts.whatsapp_reply_messages(%{
        patient: %{name: "Ana", chief_complaint: "x"},
        last_record: nil,
        transcription: "oi",
        tone: :informative
      })

    [_sys, %{content: user}] = msgs
    assert user =~ "nenhuma registrada"
  end
```
> O arquivo já tem `alias Ravanshenasi.AI.Prompts` no topo.

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/ai/prompts_test.exs --trace`
Expected: FAIL — `function ...whatsapp_reply_messages/1 is undefined`.

- [ ] **Step 3: Implementar**

Acrescentar a `lib/ravanshenasi/ai/prompts.ex`:
```elixir
  @reply_system_base """
  Você é um assistente de comunicação para psicólogos. Sua função é analisar a mensagem \
  de um paciente (transcrita de áudio) e sugerir uma resposta que o terapeuta pode enviar. \
  A resposta deve: ser escrita em primeira pessoa (como se fosse o terapeuta); NÃO fazer \
  promessas nem afirmações clínicas definitivas; ter tom conversacional (é uma mensagem de \
  WhatsApp); ter entre 3 e 6 linhas. Responda apenas com o texto da mensagem sugerida, sem introdução.
  """

  @spec whatsapp_reply_messages(map()) :: [map()]
  def whatsapp_reply_messages(%{patient: p, last_record: last, transcription: t, tone: tone}) do
    [
      %{role: "system", content: String.trim(@reply_system_base) <> "\n" <> tone_line(tone)},
      %{role: "user", content: reply_user(p, last, t)}
    ]
  end

  defp tone_line(:empathetic), do: "Tom: empático e acolhedor."
  defp tone_line(:informative), do: "Tom: informativo e objetivo, mantendo cordialidade."
  defp tone_line(:encouraging), do: "Tom: encorajador e motivador."

  defp reply_user(p, last, transcription) do
    """
    Contexto do paciente:
    - Nome: #{p.name}
    - Queixa principal: #{p.chief_complaint}
    - Última sessão: #{last_summary(last)}

    Mensagem do paciente (transcrita do áudio):
    "#{transcription}"

    Sugira uma resposta para o terapeuta enviar via WhatsApp.
    """
  end

  defp last_summary(nil), do: "(nenhuma registrada)"
  defp last_summary(%{content: c}) when is_binary(c), do: c
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/ai/prompts_test.exs --trace`
Expected: PASS.

---

## Task 5: `AI.generate_reply/1`

**Files:**
- Modify: `lib/ravanshenasi/ai.ex`
- Test: `test/ravanshenasi/ai_test.exs`

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/ai_test.exs`:
```elixir
  test "generate_reply/1 monta as mensagens e chama o chat" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:good],
      providers: %{good: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: "Oi! Estou aqui.", model: "good"}}
    )

    input = %{
      patient: %{name: "Ana", chief_complaint: "x"},
      last_record: nil,
      transcription: "oi",
      tone: :empathetic
    }

    assert {:ok, %{content: "Oi! Estou aqui.", provider: :good, model: "good"}} =
             Ravanshenasi.AI.generate_reply(input)
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/ai_test.exs --trace`
Expected: FAIL — `function Ravanshenasi.AI.generate_reply/1 is undefined`.

- [ ] **Step 3: Implementar**

Em `lib/ravanshenasi/ai.ex`, acrescentar (reusa `chat/1` e `Prompts`):
```elixir
  @spec generate_reply(map()) ::
          {:ok, %{content: String.t(), provider: atom(), model: String.t()}}
          | {:error, {:all_providers_failed, list()}}
  def generate_reply(input), do: chat(Prompts.whatsapp_reply_messages(input))
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/ai_test.exs --trace`
Expected: PASS (todos).

---

## Task 6: Migration `create_audio_messages`

**Files:**
- Create: `priv/repo/migrations/*_create_audio_messages.exs`

Espelha `create_analyses`: FK composta user→users; FK composta de 3 colunas patient (raw SQL); RLS; unique `(id, tenant_id, user_id)`.

- [ ] **Step 1: Gerar**

Run: `mix ecto.gen.migration create_audio_messages`

- [ ] **Step 2: Escrever o conteúdo**

```elixir
defmodule Ravanshenasi.Repo.Migrations.CreateAudioMessages do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:audio_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id,
          references(:users, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :restrict),
          null: false

      # 3-column composite FK via raw SQL (references/with: only does 2 cols). Ties patient↔owner.
      add :patient_id, :binary_id, null: false

      add :original_filename, :string, null: false
      add :tone, :string, null: false
      add :transcription, :text
      add :suggested_response, :text
      add :status, :string, null: false, default: "pending"
      add :transcription_model, :string
      add :reply_model_used, :string
      add :error_reason, :string

      timestamps(type: :utc_datetime)
    end

    execute(
      "ALTER TABLE audio_messages ADD CONSTRAINT audio_messages_patient_owner_fkey FOREIGN KEY (patient_id, tenant_id, user_id) REFERENCES patients (id, tenant_id, user_id) ON DELETE CASCADE",
      "ALTER TABLE audio_messages DROP CONSTRAINT audio_messages_patient_owner_fkey"
    )

    create index(:audio_messages, [:tenant_id, :user_id])
    create index(:audio_messages, [:tenant_id, :patient_id])
    create unique_index(:audio_messages, [:id, :tenant_id, :user_id])

    enable_tenant_rls("audio_messages")
  end
end
```

- [ ] **Step 3: Migrar (dev + test)**

Run: `mix ecto.migrate && MIX_ENV=test mix ecto.migrate`
Expected: tabela criada nos dois ambientes sem erro.

- [ ] **Step 4: Verificar**

Run: `mix ecto.migrations`
Expected: a migration aparece como `up`.

---

## Task 7: Schema `AudioMessage`

**Files:**
- Create: `lib/ravanshenasi/audio_messages/audio_message.ex`
- Test: `test/ravanshenasi/audio_messages/audio_message_test.exs`

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ravanshenasi/audio_messages/audio_message_test.exs`:
```elixir
defmodule Ravanshenasi.AudioMessages.AudioMessageTest do
  use ExUnit.Case, async: true
  alias Ravanshenasi.AudioMessages.AudioMessage

  test "insert_changeset válido nasce pending" do
    cs =
      AudioMessage.insert_changeset(%{
        tenant_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        patient_id: Ecto.UUID.generate(),
        original_filename: "audio.ogg",
        tone: :empathetic
      })

    assert cs.valid?
    assert Ecto.Changeset.apply_changes(cs).status == :pending
  end

  test "tone fora da whitelist → inválido" do
    cs =
      AudioMessage.insert_changeset(%{
        tenant_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        patient_id: Ecto.UUID.generate(),
        original_filename: "a.ogg",
        tone: :hacker
      })

    refute cs.valid?
  end

  test "status_changeset altera status/transcription/models/erro" do
    cs =
      AudioMessage.status_changeset(%AudioMessage{}, %{
        status: :done,
        transcription: "t",
        transcription_model: "openai:whisper-1",
        reply_model_used: "openai:gpt"
      })

    assert Ecto.Changeset.apply_changes(cs).status == :done
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/audio_messages/audio_message_test.exs --trace`
Expected: FAIL — módulo não existe.

- [ ] **Step 3: Implementar**

Criar `lib/ravanshenasi/audio_messages/audio_message.ex`:
```elixir
defmodule Ravanshenasi.AudioMessages.AudioMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audio_messages" do
    field :original_filename, :string
    field :tone, Ecto.Enum, values: [:empathetic, :informative, :encouraging]
    field :transcription, :string
    field :suggested_response, :string

    field :status, Ecto.Enum,
      values: [:pending, :transcribing, :suggesting, :done, :error],
      default: :pending

    field :transcription_model, :string
    field :reply_model_used, :string
    field :error_reason, :string

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User
    belongs_to :patient, Ravanshenasi.Patients.Patient

    timestamps(type: :utc_datetime)
  end

  @doc "Insert changeset (pending). tone/tenant/user/patient/filename são server-side."
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:tenant_id, :user_id, :patient_id, :original_filename, :tone])
    |> validate_required([:tenant_id, :user_id, :patient_id, :original_filename, :tone])
  end

  @doc "Status/etapas (transcrição, sugestão, erro)."
  def status_changeset(audio_message, attrs) do
    cast(audio_message, attrs, [
      :status,
      :transcription,
      :suggested_response,
      :transcription_model,
      :reply_model_used,
      :error_reason
    ])
  end

  @doc "Edição da resposta sugerida pelo profissional."
  def response_changeset(audio_message, attrs) do
    audio_message
    |> cast(attrs, [:suggested_response])
    |> validate_required([:suggested_response])
  end
end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/audio_messages/audio_message_test.exs --trace`
Expected: PASS (3 testes).

---

## Task 8: `AudioMessages` — `create_audio_message` + `get` + pubsub/job + stub worker

**Files:**
- Create: `lib/ravanshenasi/audio_messages.ex`
- Create: `lib/ravanshenasi/audio_messages/transcribe_and_suggest_worker.ex` (stub)
- Test: `test/ravanshenasi/audio_messages_test.exs`

`create_audio_message`: `clinical_access?` → recarrega paciente escopado → sanitiza filename → insere `pending` + `Oban.insert!`. **Tudo inline num `transact_tenant`** (não aninhar).

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ravanshenasi/audio_messages_test.exs`:
```elixir
defmodule Ravanshenasi.AudioMessagesTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{AudioMessages, Patients}
  alias Ravanshenasi.AudioMessages.TranscribeAndSuggestWorker

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    %{scope: scope, patient: patient}
  end

  defp attrs(extra \\ %{}) do
    Map.merge(%{audio_path: "/tmp/x.ogg", original_filename: "audio.ogg", tone: :empathetic}, extra)
  end

  test "create_audio_message cria pending + enfileira job", %{scope: s, patient: p} do
    assert {:ok, msg} = AudioMessages.create_audio_message(s, p, attrs())
    assert msg.status == :pending
    assert msg.tone == :empathetic
    assert_enqueued(worker: TranscribeAndSuggestWorker, args: %{audio_message_id: msg.id})
  end

  test "sanitiza original_filename (basename, sem path)", %{scope: s, patient: p} do
    {:ok, msg} = AudioMessages.create_audio_message(s, p, attrs(%{original_filename: "/etc/passwd/../áudio do João.ogg"}))
    refute msg.original_filename =~ "/"
    assert msg.original_filename == "áudio do João.ogg"
  end

  test "tom inválido (string fora da whitelist) → erro, sem job", %{scope: s, patient: p} do
    assert {:error, %Ecto.Changeset{}} = AudioMessages.create_audio_message(s, p, attrs(%{tone: "hacker"}))
    assert [] = all_enqueued(worker: TranscribeAndSuggestWorker)
  end

  test "paciente de OUTRO profissional → :unauthorized" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})
    assert {:error, :unauthorized} = AudioMessages.create_audio_message(b, pa, %{audio_path: "/tmp/x.ogg", original_filename: "a.ogg", tone: :empathetic})
  end

  test "admin de clínica → :unauthorized", %{patient: p} do
    admin = clinic_admin_scope_fixture()
    assert {:error, :unauthorized} = AudioMessages.create_audio_message(admin, p, %{audio_path: "/tmp/x.ogg", original_filename: "a.ogg", tone: :empathetic})
  end

  test "get_audio_message escopa por dono", %{scope: s, patient: p} do
    {:ok, msg} = AudioMessages.create_audio_message(s, p, attrs())
    assert AudioMessages.get_audio_message(s, msg.id).id == msg.id
    other = user_scope_fixture()
    assert AudioMessages.get_audio_message(other, msg.id) == nil
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/audio_messages_test.exs --trace`
Expected: FAIL — módulo `Ravanshenasi.AudioMessages` não existe.

- [ ] **Step 3: Implementar (stub do worker + context p1)**

Criar `lib/ravanshenasi/audio_messages/transcribe_and_suggest_worker.ex` (stub; T11 completa):
```elixir
defmodule Ravanshenasi.AudioMessages.TranscribeAndSuggestWorker do
  use Oban.Worker, queue: :ai, max_attempts: 3
  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end
```

Criar `lib/ravanshenasi/audio_messages.ex`:
```elixir
defmodule Ravanshenasi.AudioMessages do
  @moduledoc "WhatsApp audio: transcription + reply suggestion, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.AudioMessages.{AudioMessage, TranscribeAndSuggestWorker}
  alias Ravanshenasi.Patients.Patient
  alias Ravanshenasi.Repo

  @pubsub Ravanshenasi.PubSub

  @doc """
  Cria uma audio_message. NÃO confia no struct: recarrega o paciente escopado, sanitiza o
  filename (user input) e insere pending + enfileira. Tudo num único transact_tenant.
  """
  def create_audio_message(%Scope{} = scope, %{id: patient_id}, attrs) do
    if Scope.clinical_access?(scope),
      do: do_create(scope, patient_id, attrs),
      else: {:error, :unauthorized}
  end

  defp do_create(scope, patient_id, attrs) do
    transact_tenant(scope, fn ->
      case Patient |> patient_scoped(scope) |> Repo.get(patient_id) do
        nil ->
          {:error, :unauthorized}

        _patient ->
          insert =
            %{
              tenant_id: scope.tenant.id,
              user_id: scope.user.id,
              patient_id: patient_id,
              original_filename: sanitize_filename(attrs[:original_filename]),
              tone: attrs[:tone]
            }
            |> AudioMessage.insert_changeset()
            |> Repo.insert()

          case insert do
            {:ok, msg} ->
              Oban.insert!(TranscribeAndSuggestWorker.new(job_args(msg, attrs[:audio_path])))
              {:ok, msg}

            {:error, changeset} ->
              {:error, changeset}
          end
      end
    end)
  end

  # Sanitiza o filename (user input, pode conter dado clínico): só basename, ≤255 chars,
  # NUNCA usado como path (o path temp usa UUID).
  defp sanitize_filename(name) when is_binary(name), do: name |> Path.basename() |> String.slice(0, 255)
  defp sanitize_filename(_), do: "audio"

  def get_audio_message(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> AudioMessage |> scoped(scope) |> Repo.get(id) end)

  def get_audio_message!(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> AudioMessage |> scoped(scope) |> Repo.get!(id) end)

  # --- pubsub / job ---
  def subscribe(audio_message_id),
    do: Phoenix.PubSub.subscribe(@pubsub, "audio:#{audio_message_id}")

  def broadcast(%AudioMessage{} = m),
    do: Phoenix.PubSub.broadcast(@pubsub, "audio:#{m.id}", {:audio_updated, m})

  def job_args(%AudioMessage{} = m, audio_path),
    do: %{audio_message_id: m.id, user_id: m.user_id, tenant_id: m.tenant_id, audio_path: audio_path}

  defp scoped(query, scope),
    do: from(x in query, where: x.tenant_id == ^scope.tenant.id and x.user_id == ^scope.user.id)

  defp patient_scoped(query, scope),
    do: from(p in query, where: p.tenant_id == ^scope.tenant.id and p.user_id == ^scope.user.id)

  defdelegate transact_tenant(scope, fun), to: Repo
end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/audio_messages_test.exs --trace`
Expected: PASS (6 testes).

---

## Task 9: `AudioMessages` — internos (`mark_transcribing`/`save_transcription`/`complete`/`fail`) + `list`

**Files:**
- Modify: `lib/ravanshenasi/audio_messages.ex`
- Test: `test/ravanshenasi/audio_messages_test.exs`

Idempotentes (Oban at-least-once): `mark_transcribing` não regride terminal; `save_transcription` no-op se já há transcrição; `complete`/`fail` no-op se já `:done`.

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/audio_messages_test.exs`:
```elixir
  test "fluxo transcrição→sugestão grava campos + broadcast + idempotência", %{scope: s, patient: p} do
    {:ok, m} = AudioMessages.create_audio_message(s, p, attrs())
    AudioMessages.subscribe(m.id)

    assert {:ok, m} = AudioMessages.mark_transcribing(s, m)
    assert m.status == :transcribing
    assert_receive {:audio_updated, %{status: :transcribing}}

    assert {:ok, m} = AudioMessages.save_transcription(s, m, "tô mal", "openai:whisper-1")
    assert m.status == :suggesting and m.transcription == "tô mal"
    assert m.transcription_model == "openai:whisper-1"

    assert {:ok, done} = AudioMessages.complete(s, m, "Estou aqui com você.", "openai:gpt")
    assert done.status == :done and done.suggested_response == "Estou aqui com você."
    assert done.reply_model_used == "openai:gpt"

    # idempotência: complete de novo é no-op (não muda nem duplica)
    assert {:ok, again} = AudioMessages.complete(s, done, "OUTRO", "openai:gpt")
    assert again.suggested_response == "Estou aqui com você."

    # mark_transcribing em done não regride
    assert {:ok, still} = AudioMessages.mark_transcribing(s, done)
    assert still.status == :done
  end

  test "fail grava error + error_reason", %{scope: s, patient: p} do
    {:ok, m} = AudioMessages.create_audio_message(s, p, attrs())
    assert {:ok, m} = AudioMessages.fail(s, m, :audio_file_missing)
    assert m.status == :error and m.error_reason =~ "audio_file_missing"
  end

  test "list_audio_messages do paciente do dono; não vaza pra outro therapist" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})
    {:ok, m} = AudioMessages.create_audio_message(a, pa, %{audio_path: "/tmp/x.ogg", original_filename: "a.ogg", tone: :empathetic})

    assert Enum.map(AudioMessages.list_audio_messages(a, %{id: pa.id}), & &1.id) == [m.id]
    assert AudioMessages.list_audio_messages(b, %{id: pa.id}) == []
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/audio_messages_test.exs --trace`
Expected: FAIL — `function ...mark_transcribing/2 is undefined`.

- [ ] **Step 3: Implementar**

Acrescentar a `lib/ravanshenasi/audio_messages.ex` (antes do bloco pubsub/job):
```elixir
  @doc "Marca transcribing. No-op em done/error (não regride). Broadcast."
  def mark_transcribing(%Scope{} = scope, %{id: id}) do
    update_status(scope, id, fn
      %AudioMessage{status: s} = m when s in [:pending, :transcribing] ->
        AudioMessage.status_changeset(m, %{status: :transcribing})

      %AudioMessage{} = m ->
        # done/error/suggesting são terminais/avançados: não regride numa reexecução
        Ecto.Changeset.change(m)
    end)
  end

  @doc "Grava a transcrição (status :suggesting) + transcription_model. No-op se já há transcrição."
  def save_transcription(%Scope{} = scope, %{id: id}, text, transcription_model) do
    update_status(scope, id, fn
      %AudioMessage{transcription: nil} = m ->
        AudioMessage.status_changeset(m, %{
          status: :suggesting,
          transcription: text,
          transcription_model: transcription_model
        })

      %AudioMessage{} = m ->
        Ecto.Changeset.change(m)
    end)
  end

  @doc "Grava a resposta (status :done) + reply_model_used. No-op se já :done."
  def complete(%Scope{} = scope, %{id: id}, suggested_response, reply_model) do
    update_status(scope, id, fn
      %AudioMessage{status: :done} = m ->
        Ecto.Changeset.change(m)

      %AudioMessage{} = m ->
        AudioMessage.status_changeset(m, %{
          status: :done,
          suggested_response: suggested_response,
          reply_model_used: reply_model
        })
    end)
  end

  @doc "Marca error + error_reason. No-op se já :done."
  def fail(%Scope{} = scope, %{id: id}, reason) do
    update_status(scope, id, fn
      %AudioMessage{status: :done} = m ->
        Ecto.Changeset.change(m)

      %AudioMessage{} = m ->
        AudioMessage.status_changeset(m, %{status: :error, error_reason: inspect(reason)})
    end)
  end

  @doc "Histórico de áudios do paciente (do dono), mais recentes primeiro. Read escopa por id."
  def list_audio_messages(%Scope{} = scope, %{id: patient_id}) do
    transact_tenant(scope, fn ->
      AudioMessage
      |> scoped(scope)
      |> where([m], m.patient_id == ^patient_id)
      |> order_by([m], desc: m.inserted_at)
      |> Repo.all()
    end)
  end

  # Recarrega escopado por id, aplica a transição (fun devolve um changeset) e faz broadcast.
  defp update_status(scope, id, fun) do
    res =
      transact_tenant(scope, fn ->
        case AudioMessage |> scoped(scope) |> Repo.get(id) do
          nil -> {:error, :unauthorized}
          m -> m |> fun.() |> Repo.update()
        end
      end)

    with {:ok, m} <- res, do: broadcast(m)
    res
  end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/audio_messages_test.exs --trace`
Expected: PASS (testes da T8 + os 3 novos).

---

## Task 10: `AudioMessages` — `update_suggested_response` + `retry_suggestion`

**Files:**
- Modify: `lib/ravanshenasi/audio_messages.ex`
- Test: `test/ravanshenasi/audio_messages_test.exs`

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/audio_messages_test.exs`:
```elixir
  alias Ravanshenasi.AudioMessages.TranscribeAndSuggestWorker

  test "update_suggested_response edita só quando :done; alheio → :unauthorized", %{scope: s, patient: p} do
    {:ok, m} = AudioMessages.create_audio_message(s, p, attrs())
    {:ok, m} = AudioMessages.save_transcription(s, m, "t", "openai:whisper-1")
    {:ok, m} = AudioMessages.complete(s, m, "resposta", "openai:gpt")

    assert {:ok, edited} = AudioMessages.update_suggested_response(s, m, "minha edição")
    assert edited.suggested_response == "minha edição"

    other = user_scope_fixture()
    assert {:error, :unauthorized} = AudioMessages.update_suggested_response(other, m, "hack")
  end

  test "retry_suggestion só com :error + transcrição: volta a :suggesting e re-enfileira", %{scope: s, patient: p} do
    {:ok, m} = AudioMessages.create_audio_message(s, p, attrs())
    {:ok, m} = AudioMessages.save_transcription(s, m, "t", "openai:whisper-1")
    {:ok, m} = AudioMessages.fail(s, m, :provider_down)

    assert {:ok, retried} = AudioMessages.retry_suggestion(s, m)
    assert retried.status == :suggesting
    assert_enqueued(worker: TranscribeAndSuggestWorker, args: %{audio_message_id: m.id})
  end

  test "retry_suggestion sem transcrição (erro na etapa 1) → {:error, :not_retryable}", %{scope: s, patient: p} do
    {:ok, m} = AudioMessages.create_audio_message(s, p, attrs())
    {:ok, m} = AudioMessages.fail(s, m, :audio_file_missing)
    assert {:error, :not_retryable} = AudioMessages.retry_suggestion(s, m)
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/audio_messages_test.exs --trace`
Expected: FAIL — `function ...update_suggested_response/3 is undefined`.

- [ ] **Step 3: Implementar**

Acrescentar a `lib/ravanshenasi/audio_messages.ex`:
```elixir
  @doc "Edição da resposta pelo profissional (só quando :done). Recarrega escopado por id."
  def update_suggested_response(%Scope{} = scope, %{id: id}, text) do
    transact_tenant(scope, fn ->
      case AudioMessage |> scoped(scope) |> Repo.get(id) do
        nil -> {:error, :unauthorized}
        %AudioMessage{status: :done} = m -> m |> AudioMessage.response_changeset(%{suggested_response: text}) |> Repo.update()
        %AudioMessage{} -> {:error, :not_editable}
      end
    end)
  end

  @doc """
  Re-tenta SÓ a etapa 2 (sugestão): exige :error + transcrição presente. Volta pra :suggesting
  e re-enfileira (audio_path: nil — a etapa 1 é pulada). Erro de transcrição (sem transcription)
  não é retryável: exige novo upload.
  """
  def retry_suggestion(%Scope{} = scope, %{id: id}) do
    transact_tenant(scope, fn ->
      case AudioMessage |> scoped(scope) |> Repo.get(id) do
        %AudioMessage{status: :error, transcription: t} = m when is_binary(t) ->
          {:ok, m} = m |> AudioMessage.status_changeset(%{status: :suggesting, error_reason: nil}) |> Repo.update()
          Oban.insert!(TranscribeAndSuggestWorker.new(job_args(m, nil)))
          {:ok, m}

        %AudioMessage{} ->
          {:error, :not_retryable}

        nil ->
          {:error, :unauthorized}
      end
    end)
  end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/audio_messages_test.exs --trace`
Expected: PASS (todos).

---

## Task 11: `TranscribeAndSuggestWorker` (completo)

**Files:**
- Modify: `lib/ravanshenasi/audio_messages/transcribe_and_suggest_worker.ex` (substitui o stub)
- Test: `test/ravanshenasi/audio_messages/transcribe_and_suggest_worker_test.exs`

2 etapas idempotentes, guarda `:audio_file_missing` terminal, IA fora de transação, binário descartado.

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ravanshenasi/audio_messages/transcribe_and_suggest_worker_test.exs`:
```elixir
defmodule Ravanshenasi.AudioMessages.TranscribeAndSuggestWorkerTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{AudioMessages, Patients}
  alias Ravanshenasi.AudioMessages.TranscribeAndSuggestWorker

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    # arquivo de áudio temporário real (o worker vai apagá-lo após transcrever)
    path = Path.join(System.tmp_dir!(), "wav_#{System.unique_integer([:positive])}.ogg")
    File.write!(path, "fake")
    {:ok, msg} = AudioMessages.create_audio_message(scope, patient, %{audio_path: path, original_filename: "a.ogg", tone: :empathetic})
    on_exit(fn -> File.rm(path) end)
    %{scope: scope, msg: msg, path: path}
  end

  defp args(msg, path), do: %{"audio_message_id" => msg.id, "user_id" => msg.user_id, "tenant_id" => msg.tenant_id, "audio_path" => path}

  test "sucesso nas 2 etapas → done + transcrição + resposta + binário apagado", %{scope: s, msg: m, path: path} do
    # stub: transcrição "olá, tudo bem?" (config/test.exs) + chat "stub..." (config/test.exs)
    assert :ok = perform_job(TranscribeAndSuggestWorker, args(m, path))
    done = AudioMessages.get_audio_message(s, m.id)
    assert done.status == :done
    assert done.transcription == "olá, tudo bem?"
    assert is_binary(done.suggested_response) and done.suggested_response != ""
    assert done.transcription_model == "stub:stub-model" or done.transcription_model =~ "stub"
    refute File.exists?(path)
  end

  test "binário sumiu (audio_path inexistente) + sem transcrição → error :audio_file_missing terminal", %{scope: s, msg: m} do
    assert :ok = perform_job(TranscribeAndSuggestWorker, args(m, "/nao/existe.ogg"))
    failed = AudioMessages.get_audio_message(s, m.id)
    assert failed.status == :error
    assert failed.error_reason =~ "audio_file_missing"
  end

  test "reexecução de job já done é no-op (não duplica/regride)", %{scope: s, msg: m, path: path} do
    assert :ok = perform_job(TranscribeAndSuggestWorker, args(m, path))
    assert :ok = perform_job(TranscribeAndSuggestWorker, args(m, "/qualquer.ogg"))
    assert AudioMessages.get_audio_message(s, m.id).status == :done
  end

  test "falha na transcrição no último attempt → error", %{scope: s, msg: m, path: path} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      Keyword.merge(prev,
        transcription: %{order: [:bad], providers: %{bad: %{client: Ravanshenasi.AI.Transcriber.Stub, behavior: :error, model: "bad"}}}
      )
    )

    assert :ok = perform_job(TranscribeAndSuggestWorker, args(m, path), attempt: 3)
    failed = AudioMessages.get_audio_message(s, m.id)
    assert failed.status == :error
    # o reason real do provider é preservado pra diagnóstico (não só :transcription_failed)
    assert failed.error_reason =~ "transcription_failed"
  end
end
```
> Nota: `Application.get_env(:ravanshenasi, Ravanshenasi.AI)` é um keyword list (`order`/`providers`/`transcription`); `Keyword.merge` troca só a chave `transcription`, mantendo o chat stub pra etapa 2 (que não é alcançada quando a transcrição falha).

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/audio_messages/transcribe_and_suggest_worker_test.exs --trace`
Expected: FAIL — o stub do worker devolve `:ok` sem mudar nada (`status` continua `:pending`).

- [ ] **Step 3: Implementar (substituir o stub)**

Substituir `lib/ravanshenasi/audio_messages/transcribe_and_suggest_worker.ex` por:
```elixir
defmodule Ravanshenasi.AudioMessages.TranscribeAndSuggestWorker do
  @moduledoc "Oban worker: transcribes the audio (Whisper) then suggests a WhatsApp reply (chat)."

  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Ravanshenasi.Accounts.{Scope, Tenant, User}
  alias Ravanshenasi.{AI, AudioMessages, Patients, Records}
  alias Ravanshenasi.AudioMessages.AudioMessage
  alias Ravanshenasi.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max}) do
    %{"audio_message_id" => id, "user_id" => uid, "tenant_id" => tid} = args
    audio_path = args["audio_path"]

    with {:ok, scope} <- build_scope(uid, tid),
         %AudioMessage{} = msg <- AudioMessages.get_audio_message(scope, id) do
      process(scope, msg, audio_path, attempt, max)
    else
      nil -> {:discard, :not_found}
      {:error, :not_found} -> {:discard, :not_found}
    end
  end

  # Terminal (done/error): job já concluído numa execução anterior (at-least-once). No-op.
  defp process(_scope, %AudioMessage{status: st}, _path, _a, _m) when st in [:done, :error], do: :ok

  # Transcrição ainda não feita.
  defp process(scope, %AudioMessage{transcription: nil} = msg, audio_path, attempt, max) do
    if is_binary(audio_path) and File.exists?(audio_path) do
      transcribe_step(scope, msg, audio_path, attempt, max)
    else
      # Binário sumiu e não há transcrição: irreversível. Erro terminal, SEM retry.
      {:ok, _} = AudioMessages.fail(scope, msg, :audio_file_missing)
      :ok
    end
  end

  # Transcrição já feita (retry da etapa 2): pula a etapa 1, vai direto pra sugestão.
  defp process(scope, %AudioMessage{} = msg, _audio_path, attempt, max) do
    suggest_step(scope, msg, attempt, max)
  end

  defp transcribe_step(scope, msg, audio_path, attempt, max) do
    {:ok, _} = AudioMessages.mark_transcribing(scope, msg)

    case AI.transcribe(audio_path) do
      {:ok, %{text: text, provider: provider, model: model}} ->
        {:ok, msg} = AudioMessages.save_transcription(scope, msg, text, "#{provider}:#{model}")
        File.rm(audio_path)
        suggest_step(scope, msg, attempt, max)

      {:error, reason} when attempt >= max ->
        # Persiste o reason REAL (erro de API, audio_unreadable, empty_transcription…) pra diagnóstico.
        {:ok, _} = AudioMessages.fail(scope, msg, {:transcription_failed, reason})
        File.rm(audio_path)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp suggest_step(scope, msg, attempt, max) do
    case AI.generate_reply(build_input(scope, msg)) do
      {:ok, %{content: content, provider: provider, model: model}} ->
        {:ok, _} = AudioMessages.complete(scope, msg, content, "#{provider}:#{model}")
        :ok

      {:error, reason} when attempt >= max ->
        {:ok, _} = AudioMessages.fail(scope, msg, {:suggestion_failed, reason})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_input(scope, msg) do
    patient = Patients.get_patient!(scope, msg.patient_id)

    %{
      patient: patient,
      last_record: List.first(Records.recent_done_records(scope, %{id: patient.id}, 1)),
      transcription: msg.transcription,
      tone: msg.tone
    }
  end

  defp build_scope(uid, tid) do
    Repo.with_auth_bypass(fn ->
      with %User{tenant_id: ^tid} = user <- Repo.get(User, uid),
           %Tenant{} = tenant <- Repo.get(Tenant, tid) do
        {:ok, Scope.for_user(user) |> Scope.put_tenant(tenant)}
      else
        _ -> {:error, :not_found}
      end
    end)
  end
end
```
> `suggest_step` recebe a `msg` recarregada por `save_transcription` (que devolve a struct com `transcription` preenchida). No retry da etapa 2, a `msg` carregada do banco já tem `transcription`.

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/audio_messages/transcribe_and_suggest_worker_test.exs --trace`
Expected: PASS (4 testes).

---

## Task 12: Router + `AudioLive.Index` (upload + lista + states + gate)

**Files:**
- Modify: `lib/ravanshenasi_web/router.ex`
- Create: `lib/ravanshenasi_web/live/audio_live/index.ex`
- Test: `test/ravanshenasi_web/live/audio_live_test.exs`

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ravanshenasi_web/live/audio_live_test.exs`:
```elixir
defmodule RavanshenasiWeb.AudioLiveTest do
  use RavanshenasiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{AudioMessages, Patients}

  setup %{conn: conn} do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    %{conn: log_in_user(conn, scope.user), scope: scope, patient: patient}
  end

  test "upload cria a msg pending e ela aparece na lista", %{conn: conn, scope: s, patient: p} do
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/audios")

    audio = file_input(lv, "#audio-upload-form", :audio, [%{name: "a.ogg", content: "fake", type: "audio/ogg"}])
    render_upload(audio, "a.ogg")
    lv |> form("#audio-upload-form", %{"tone" => "empathetic"}) |> render_submit()

    assert [msg] = AudioMessages.list_audio_messages(s, %{id: p.id})
    assert msg.status == :pending
    # data-status é estável e independente de locale (o texto do label é traduzido)
    assert has_element?(lv, "#audio-status-#{msg.id}[data-status=pending]")
  end

  test "broadcast atualiza: transcrevendo → resposta editável", %{conn: conn, scope: s, patient: p} do
    # criada ANTES do live/2 → o mount carrega e (conectado) assina o tópico
    {:ok, m} = AudioMessages.create_audio_message(s, p, %{audio_path: "/tmp/x.ogg", original_filename: "a.ogg", tone: :empathetic})
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/audios")

    {:ok, _} = AudioMessages.mark_transcribing(s, m)
    assert has_element?(lv, "#audio-status-#{m.id}[data-status=transcribing]")

    {:ok, m} = AudioMessages.save_transcription(s, m, "tô mal", "openai:whisper-1")
    {:ok, _} = AudioMessages.complete(s, m, "Estou aqui.", "openai:gpt")

    assert has_element?(lv, "#transcription-#{m.id}", "tô mal")
    assert has_element?(lv, "#suggested-response-#{m.id}")
    assert has_element?(lv, "#audio-status-#{m.id}[data-status=done]")
  end

  test "clinic admin é barrado pelo live_session :require_clinical", %{conn: conn} do
    admin = clinic_admin_scope_fixture()
    {:ok, p} = Patients.create_patient(therapist_scope_fixture(admin.tenant), %{name: "P"})
    conn = log_in_user(conn, admin.user)
    assert {:error, {:redirect, _}} = live(conn, ~p"/pacientes/#{p.id}/audios")
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi_web/live/audio_live_test.exs --trace`
Expected: FAIL — rota `/pacientes/:patient_id/audios` não existe.

- [ ] **Step 3: Adicionar a rota**

Em `lib/ravanshenasi_web/router.ex`, **dentro do `live_session :require_clinical`** (o mesmo bloco de `/pacientes` e `/sessoes`), após a linha `live "/pacientes/:patient_id/sessoes/:id", SessionLive.Show, :show`, acrescentar:
```elixir
      live "/pacientes/:patient_id/audios", AudioLive.Index, :index
```

- [ ] **Step 4: Implementar a LiveView**

Criar `lib/ravanshenasi_web/live/audio_live/index.ex`:
```elixir
defmodule RavanshenasiWeb.AudioLive.Index do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.{AudioMessages, Patients}

  @tones [{"Empático", "empathetic"}, {"Informativo", "informative"}, {"Encorajador", "encouraging"}]

  @impl true
  def mount(%{"patient_id" => pid}, _session, socket) do
    scope = socket.assigns.current_scope
    patient = Patients.get_patient!(scope, pid)
    audios = AudioMessages.list_audio_messages(scope, %{id: patient.id})

    # subscribe só no socket conectado (evita subscribe inútil no render desconectado)
    if connected?(socket) do
      for a <- audios, a.status in [:pending, :transcribing, :suggesting], do: AudioMessages.subscribe(a.id)
    end

    {:ok,
     socket
     |> assign(patient: patient, audios: audios, tones: @tones)
     |> allow_upload(:audio, accept: ~w(.ogg .mp3 .m4a .wav), max_file_size: 25_000_000, max_entries: 1)}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("transcribe", %{"tone" => tone}, socket) do
    scope = socket.assigns.current_scope
    patient = socket.assigns.patient

    consumed =
      consume_uploaded_entries(socket, :audio, fn %{path: tmp}, entry ->
        dir = Path.join(System.tmp_dir!(), "ravanshenasi_audio")
        File.mkdir_p!(dir)
        dest = Path.join(dir, "#{Ecto.UUID.generate()}#{Path.extname(entry.client_name)}")
        File.cp!(tmp, dest)
        {:ok, {dest, entry.client_name}}
      end)

    case consumed do
      [{audio_path, filename}] ->
        case AudioMessages.create_audio_message(scope, patient, %{audio_path: audio_path, original_filename: filename, tone: tone}) do
          {:ok, msg} ->
            AudioMessages.subscribe(msg.id)
            {:noreply, assign(socket, audios: [msg | socket.assigns.audios])}

          {:error, :unauthorized} ->
            # create falhou: remove o binário copiado pra não deixar órfão no tmp
            File.rm(audio_path)
            {:noreply, put_flash(socket, :error, gettext("Not allowed"))}

          {:error, _} ->
            File.rm(audio_path)
            {:noreply, put_flash(socket, :error, gettext("Could not process the audio"))}
        end

      [] ->
        {:noreply, put_flash(socket, :error, gettext("Select an audio file"))}
    end
  end

  @impl true
  def handle_info({:audio_updated, msg}, socket) do
    audios = Enum.map(socket.assigns.audios, fn a -> if a.id == msg.id, do: msg, else: a end)
    {:noreply, assign(socket, audios: audios)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>{gettext("WhatsApp audios")} — {@patient.name}</.header>

      <form id="audio-upload-form" phx-submit="transcribe" phx-change="validate">
        <.live_file_input upload={@uploads.audio} />
        <select name="tone">
          <option :for={{label, value} <- @tones} value={value}>{label}</option>
        </select>
        <.button type="submit">{gettext("Transcribe and suggest")}</.button>
      </form>

      <ul id="audios">
        <li :for={a <- @audios} id={"audio-#{a.id}"}>
          <span>{a.original_filename}</span>
          <span id={"audio-status-#{a.id}"} data-status={a.status}>{status_label(a.status)}</span>

          <p :if={a.transcription} id={"transcription-#{a.id}"}>{a.transcription}</p>

          <div :if={a.status == :done}>
            <textarea id={"suggested-response-#{a.id}"} rows="5">{a.suggested_response}</textarea>
          </div>

          <p :if={a.status == :error} id={"audio-error-#{a.id}"}>{gettext("Failed.")} {a.error_reason}</p>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  defp status_label(:pending), do: gettext("Queued…")
  defp status_label(:transcribing), do: gettext("Transcribing…")
  defp status_label(:suggesting), do: gettext("Generating reply…")
  defp status_label(:done), do: gettext("Done")
  defp status_label(:error), do: gettext("Error")
end
```

- [ ] **Step 5: Rodar e ver passar**

Run: `mix test test/ravanshenasi_web/live/audio_live_test.exs --trace`
Expected: PASS (3 testes).

---

## Task 13: `AudioLive` — editar resposta, retry, copiar (clipboard)

**Files:**
- Modify: `lib/ravanshenasi_web/live/audio_live/index.ex` (handlers + render + **colocated hook** `Copy`)
- Test: `test/ravanshenasi_web/live/audio_live_test.exs`

> O projeto usa **colocated hooks** (o `app.js` já tem `hooks: {...colocatedHooks}`). O hook `Copy` é definido **dentro do próprio `render/1`** via `<script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">` e referenciado com `phx-hook=".Copy"` (o ponto = namespaced ao módulo). **Não edita `app.js`.**

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi_web/live/audio_live_test.exs`:
```elixir
  test "salvar edição da resposta persiste", %{conn: conn, scope: s, patient: p} do
    {:ok, m} = AudioMessages.create_audio_message(s, p, %{audio_path: "/tmp/x.ogg", original_filename: "a.ogg", tone: :empathetic})
    {:ok, m} = AudioMessages.save_transcription(s, m, "t", "openai:whisper-1")
    {:ok, _} = AudioMessages.complete(s, m, "original", "openai:gpt")

    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/audios")
    lv |> form("#response-form-#{m.id}", %{"response" => "editada por mim"}) |> render_submit()

    assert AudioMessages.get_audio_message(s, m.id).suggested_response == "editada por mim"
    assert has_element?(lv, "#copy-response-#{m.id}")
  end

  test "retry de erro na etapa 2 (com transcrição) re-enfileira", %{conn: conn, scope: s, patient: p} do
    {:ok, m} = AudioMessages.create_audio_message(s, p, %{audio_path: "/tmp/x.ogg", original_filename: "a.ogg", tone: :empathetic})
    {:ok, m} = AudioMessages.save_transcription(s, m, "t", "openai:whisper-1")
    {:ok, _} = AudioMessages.fail(s, m, :suggestion_failed)

    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/audios")
    lv |> element("#retry-audio-#{m.id}") |> render_click()

    assert AudioMessages.get_audio_message(s, m.id).status == :suggesting
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi_web/live/audio_live_test.exs --trace`
Expected: FAIL — `#response-form-...`/`#retry-audio-...` não existem.

- [ ] **Step 3: Implementar os handlers + render**

Em `lib/ravanshenasi_web/live/audio_live/index.ex`, acrescentar os handlers (após `handle_event("transcribe", ...)`):
```elixir
  @impl true
  def handle_event("save-response", %{"id" => id, "response" => text}, socket) do
    case AudioMessages.update_suggested_response(socket.assigns.current_scope, %{id: id}, text) do
      {:ok, msg} ->
        audios = Enum.map(socket.assigns.audios, fn a -> if a.id == msg.id, do: msg, else: a end)
        {:noreply, socket |> assign(audios: audios) |> put_flash(:info, gettext("Saved"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save"))}
    end
  end

  @impl true
  def handle_event("retry-audio", %{"id" => id}, socket) do
    case AudioMessages.retry_suggestion(socket.assigns.current_scope, %{id: id}) do
      {:ok, msg} ->
        AudioMessages.subscribe(msg.id)
        audios = Enum.map(socket.assigns.audios, fn a -> if a.id == msg.id, do: msg, else: a end)
        {:noreply, assign(socket, audios: audios)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not retry"))}
    end
  end
```

Substituir o bloco `<div :if={a.status == :done}>` do render por (form de edição + copiar):
```elixir
          <div :if={a.status == :done}>
            <form id={"response-form-#{a.id}"} phx-submit="save-response">
              <input type="hidden" name="id" value={a.id} />
              <textarea id={"suggested-response-#{a.id}"} name="response" rows="5">{a.suggested_response}</textarea>
              <.button type="submit">{gettext("Save")}</.button>
              <button
                type="button"
                id={"copy-response-#{a.id}"}
                phx-hook=".Copy"
                data-target={"#suggested-response-#{a.id}"}
              >
                {gettext("Copy")}
              </button>
            </form>
          </div>
```

Substituir o bloco `<p :if={a.status == :error} ...>` por (mensagem + retry quando há transcrição):
```elixir
          <div :if={a.status == :error} id={"audio-error-#{a.id}"}>
            <p>{gettext("Failed.")} {a.error_reason}</p>
            <.button :if={a.transcription} id={"retry-audio-#{a.id}"} phx-click="retry-audio" phx-value-id={a.id}>
              {gettext("Try again")}
            </.button>
            <p :if={is_nil(a.transcription)}>{gettext("Please upload the audio again.")}</p>
          </div>
```

- [ ] **Step 4: Definir o colocated hook `Copy` no render**

O `app.js` já carrega `hooks: {...colocatedHooks}`, então o hook vai **dentro do `~H` do `render/1`** (no fim, antes de fechar `</Layouts.app>`). Acrescentar:
```elixir
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const target = document.querySelector(this.el.dataset.target)
              if (target) { target.select(); navigator.clipboard.writeText(target.value) }
            })
          }
        }
      </script>
```
O botão `#copy-response-<id>` usa `phx-hook=".Copy"` (Step 3) — o `.` casa com o `name=".Copy"` namespaced a este módulo. O build (`phoenix-colocated`) extrai o script automaticamente; **não toca no `app.js`**.
> O teste não exercita o JS — só verifica a presença do botão `#copy-response-<id>`. O hook é pra runtime.

- [ ] **Step 5: Rodar e ver passar**

Run: `mix test test/ravanshenasi_web/live/audio_live_test.exs --trace`
Expected: PASS (5 testes no arquivo).

---

## Final: validação da fatia inteira

- [ ] **Step 1: Suite completa**

Run: `mix test`
Expected: TODOS verdes (os ~254 anteriores + os novos da Fatia 4). Zero falhas.

- [ ] **Step 2: precommit (format + credo + test)**

Run: `mix precommit`
Expected: verde. Credo "nesting too deep"/"function too long" → extrair helper privado e rodar de novo.

- [ ] **Step 3: Deixar pro usuário commitar**

**NÃO commitar.** Reportar arquivos criados/modificados, migrations aplicadas, contagem de testes, pendências. Working tree pronta pro usuário.

---

## Self-Review (plano vs spec)

**Spec coverage:**
- §3 (subsistema transcrição): T1 (behaviour+Stub), T2 (OpenAI multipart, File.read, vazio), T3 (transcribe/1 fallback + config). `generate_reply` T5, `whatsapp_reply_messages` T4. ✅
- §4 (modelo): T6 (migration FK composta+RLS+unique, `transcription_model`+`reply_model_used`), T7 (schema, tone/status enums). ✅
- §5 (upload/temp/descarte): T12 (allow_upload, consume_uploaded_entries→tmp UUID, content_type no T2), descarte no worker T11; filename sanitizado T8. ✅
- §6 (worker 2 etapas): T11 — scope, guarda `:audio_file_missing` terminal, idempotência done/error, File.rm, retry etapa 2 sem re-transcrever. ✅
- §7 (context): T8 (create/get/job/pubsub), T9 (mark/save/complete/fail idempotentes + list), T10 (update/retry). ✅
- §8 (autorização): clinical_access? + dono nos testes T8/T9/T10; gate de rota T12. ✅
- §9 (edge cases): T8 (unauthorized, tom inválido), T11 (audio_file_missing, transcrição/sugestão falham, reexecução done). ✅
- §10–§11 (real-time/UI): T12 (states, PubSub, gate) + T13 (editar, retry, copiar). ✅
- §13 (testes): stubs config-driven, Req.Test, Oban manual, file_input/render_upload. ✅
- §16 (DoD): cada item mapeia a uma task. ✅

**Placeholder scan:** sem TBD/TODO; todo step de código tem o código completo; comandos com expected output. O hook `Copy` é um colocated hook definido inline no render (T13 Step 4) — sem edição de `app.js`. O teste só verifica a presença do botão, não o JS.

**Type consistency:** `AI.transcribe/1`→`%{text, provider, model}`; `AI.generate_reply/1`→`%{content, provider, model}`; context `save_transcription/4`(text, transcription_model), `complete/4`(response, reply_model), `fail/3`; worker `job_args(msg, audio_path)`→`%{audio_message_id, user_id, tenant_id, audio_path}`; broadcast `{:audio_updated, msg}`; tópico `"audio:<id>"`; status `[:pending,:transcribing,:suggesting,:done,:error]`; tone `[:empathetic,:informative,:encouraging]`. Consistente entre tasks.

**Nota de dependência cruzada:** T8 cria um **stub** do worker (`perform/1 → :ok`) pra destravar `Oban.insert!`/`assert_enqueued`; T11 substitui pelo `perform` completo. Config `transcription:` entra na T3 (necessária pro facade e pros contexts/worker das tasks seguintes); o `:transcriber_req_plug` na T2.
