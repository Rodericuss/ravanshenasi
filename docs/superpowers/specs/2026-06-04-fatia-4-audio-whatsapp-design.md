# Fatia 4 — Áudio do WhatsApp (Transcrição + Sugestão de Resposta)

**Projeto:** Ravanshenasi (PsiCare) — SaaS de psicologia
**Data:** 2026-06-04
**Status:** Spec aprovado, pronto pra virar plano de implementação
**Depende de:** Fatia 0 (Fundação), Fatia 1 (Pacientes + Linhas), Fatia 2 (Sessões + Prontuário + subsistema de IA/Oban), Fatia 3 (Sugestões). Todas implementadas.
**Stack:** Phoenix 1.8.7 + LiveView 1.1 + Ecto + TimescaleDB pg17 + Oban + `req` (multipart)

---

## 1. Contexto e objetivo

Quinta fatia (Feature 6 do `AI_DESIGN.md`/`FEATURES.md`). O profissional recebe um áudio de um paciente (via WhatsApp) e faz **upload** no sistema. O fluxo tem **duas etapas de IA**:

1. **Transcrição** do áudio via Whisper (`whisper-1`, `language: pt`, multipart).
2. **Sugestão de resposta** (texto) que o terapeuta pode **editar e copiar** pra enviar no WhatsApp, gerada por um LLM (chat) no **tom** escolhido (empático / informativo / encorajador), com base no perfil do paciente + último prontuário.

Reusa a infra das fatias anteriores (Oban async, PubSub, padrão scope/RLS, subsistema de IA). A novidade técnica é: **upload de arquivo grande (≤25MB)**, **transcrição via endpoint multipart** (novo behaviour `AI.Transcriber`), e **descarte do binário** após a transcrição (privacidade clínica).

### API herdada (usar como está)
- `Ravanshenasi.AI.chat/1` (fallback `openai → nim`), `AI.Prompts`.
- `Ravanshenasi.Repo.transact_tenant/2`, `with_auth_bypass/1`; `Ravanshenasi.RLS.enable_tenant_rls/1`.
- `Scope` (`clinical_access?/1`, `admin?/1`); `Patients.get_patient!/2`; `Records.recent_done_records/3` (último prontuário `done` como contexto).
- **Padrão de segurança (Fatias 1–3):** RLS isola só por tenant; o scope isola entre profissionais. **Toda função que recebe um struct/id — read OU write — escopa a query por `tenant_id`+`user_id`** (recarrega antes de operar; nunca confia no struct do caller). Integridade entre tabelas via **FK composta** `(…, tenant_id, user_id)`. **Nunca aninhar `transact_tenant`** (ele reseta o GUC no sucesso → a transação externa ficaria fail-closed; consultar inline com query escopada).

---

## 2. Decisões de arquitetura (aprovadas)

| # | Decisão | Escolha | Justificativa |
|---|---|---|---|
| F4-D1 | Processamento | **Async (Oban, `queue: :ai`)** | "Indicador de progresso"; mesmo padrão das Fatias 2–3 |
| F4-D2 | Binário do áudio | **Descartado após a transcrição** | Privacidade clínica — o áudio do paciente vira texto e some |
| F4-D3 | Transcrição | **Behaviour novo `AI.Transcriber`** (separado do `AI.Client` de chat) | Contrato/semântica diferentes (multipart, sem o mesmo fallback) |
| F4-D4 | Compat. NIM | **`AI.Transcriber.OpenAI` protocol-agnostic + `order`/`providers`** | Simetria com o chat; OpenAI Whisper, NIM ASR ou fallback, via config/env |
| F4-D5 | Sugestão (etapa 2) | **Reusa `AI.chat/1`** (já NIM-compatível) + `Prompts.whatsapp_reply_messages/1` | Não duplica o subsistema de chat |
| F4-D6 | Tom | **Seletor no MVP** (`empathetic`/`informative`/`encouraging`) | Pedido do produto; muda só o system prompt |
| F4-D7 | UI | **Rota própria `/pacientes/:id/audios`** (`AudioLive`) | Upload + histórico; não incha o `PatientLive.Show` |
| F4-D8 | Isolamento | RLS `tenant_id` + scope `user_id` + FK composta; recarga por id | Padrão consolidado |

---

## 3. Subsistema de transcrição (`AI.Transcriber`)

Behaviour novo, paralelo ao `AI.Client` (chat). **Não** mistura os dois contratos.

```elixir
defmodule Ravanshenasi.AI.Transcriber do
  @moduledoc "Speech-to-text protocol. Implementations talk to any OpenAI-compatible /audio/transcriptions endpoint."
  @callback transcribe(provider_cfg :: map(), audio_path :: String.t(), opts :: keyword()) ::
              {:ok, text :: String.t()} | {:error, reason :: term()}
end
```

- **`AI.Transcriber.OpenAI`** (protocol-agnostic, igual o `Client.OpenAI` serve OpenAI **e** NIM): `req` multipart `POST {base_url}/audio/transcriptions` com `file` (binário + filename + content_type), `model`, `language: "pt"`. Lê o arquivo com **`File.read/1`** (nunca `File.read!/1`): ausente/ilegível → `{:error, {:audio_unreadable, posix}}` (retorna erro controlado, não levanta). Resposta `200 %{"text" => t}` **com `is_binary(t) and String.trim(t) != ""`** → `{:ok, t}`; texto vazio/ausente → `{:error, {:empty_transcription, body}}` (igual o chat rejeita conteúdo vazio); status != 200 → `{:error, {:http_error, status, body}}`; erro de rede → `{:error, reason}`. (ok ≤25MB em memória.)
- **`AI.Transcriber.Stub`** (testes, config-driven): `behavior: :error` → `{:error, cfg.error || :stub_error}`; senão `{:ok, cfg.text || "transcrição stub"}`.
- **Facade `AI.transcribe(audio_path) :: {:ok, %{text, provider, model}} | {:error, {:all_providers_failed, list()}}`**: lê `cfg[:transcription]`, tenta `order` em sequência com fallback (mesmo padrão de `try_providers/4` do chat: pula provider sem config, acumula erros, retorna o 1º `{:ok, _}` enriquecido com `provider`/`model` pra auditoria — espelha `AI.chat/1`).

### Config (`Ravanshenasi.AI`)
Acrescenta a chave `transcription:` ao config existente:
```elixir
transcription: %{
  order: [:openai],                       # runtime: AI_TRANSCRIPTION_ORDER (whitelist openai|nim)
  providers: %{
    openai: %{client: AI.Transcriber.OpenAI, base_url: "https://api.openai.com/v1", api_key: ..., model: "whisper-1"},
    nim:    %{client: AI.Transcriber.OpenAI, base_url: NIM_ASR_BASE_URL, api_key: ..., model: NIM_ASR_MODEL}
  }
}
```
Teste (`config/test.exs`): `transcription: %{order: [:stub], providers: %{stub: %{client: AI.Transcriber.Stub, text: "olá, tudo bem?"}}}`.

> **Caveat NIM (documentado):** funciona com NIM **se** o endpoint for OpenAI-compatible (`POST /audio/transcriptions` multipart). NIMs de ASR via gRPC/Riva ficam fora desta fatia; o behaviour deixa a porta aberta pra um `Transcriber.Riva` futuro sem tocar no resto.

### Etapa 2 — sugestão de resposta
- `AI.generate_reply(input) :: {:ok, %{content, provider, model}} | {:error, {:all_providers_failed, list()}}` = `chat(Prompts.whatsapp_reply_messages(input))`.
- `AI.Prompts.whatsapp_reply_messages(%{patient, last_record, transcription, tone})`:
  - **system** varia por `tone` (3 variações do prompt do `AI_DESIGN.md` F6: primeira pessoa, sem afirmações clínicas definitivas, tom de WhatsApp, 3–6 linhas; "empático/acolhedor", "informativo/objetivo", "encorajador/motivador").
  - **user** com nome, queixa, resumo do último prontuário e a transcrição. **`last_record` pode ser `nil`** (paciente sem prontuário `done`) → bloco "Última sessão: (nenhuma registrada)".

---

## 4. Modelo de dados — `audio_messages` (scope: `tenant_id` + `user_id`)

`:binary_id` PK, RLS por `tenant_id`, FK composta, acessada via `transact_tenant`.

| Coluna | Tipo | Notas |
|---|---|---|
| `id` | binary_id | PK |
| `tenant_id` | binary_id | FK → tenants, NOT NULL |
| `user_id` | binary_id | FK composta `(user_id, tenant_id) → users(id, tenant_id)`, NOT NULL |
| `patient_id` | binary_id | FK composta **`(patient_id, tenant_id, user_id) → patients(id, tenant_id, user_id)`**, NOT NULL — amarra paciente↔dono |
| `original_filename` | string | NOT NULL — exibição |
| `tone` | enum (`empathetic`,`informative`,`encouraging`) | NOT NULL, escolhido no upload |
| `transcription` | text | nullable — preenchido na etapa 1 |
| `suggested_response` | text | nullable — etapa 2, editável pelo profissional |
| `status` | enum (`pending`,`transcribing`,`suggesting`,`done`,`error`) | default `pending` |
| `transcription_model` | string | `"provider:model"` da etapa 1 (Whisper/ASR), nullable — auditoria |
| `reply_model_used` | string | `"provider:model"` da sugestão (etapa 2), nullable — auditoria |
| `error_reason` | string | nullable |
| `inserted_at`/`updated_at` | utc_datetime | |

Índices: `(tenant_id, user_id)`, `(tenant_id, patient_id)`, **unique `(id, tenant_id, user_id)`** (consistência da FK composta). RLS via `enable_tenant_rls("audio_messages")`.

**Não guarda path nem binário.** O path temporário do upload viaja **apenas nos job args** e é apagado após a transcrição.

---

## 5. Upload e armazenamento temporário

- **LiveView `allow_upload(:audio, accept: ~w(.ogg .mp3 .m4a .wav), max_file_size: 25_000_000, max_entries: 1)`**. Validação de tamanho/extensão na **borda** — arquivo inválido nem chega a criar registro.
- No submit, `consume_uploaded_entry/3` **move** o arquivo pra um diretório temporário estável: `Path.join(System.tmp_dir!(), "ravanshenasi_audio")` com nome `"<uuid>.<ext>"` (cria o dir se não existir). Esse path é passado pra `create_audio_message`.
- O **content_type** pra o multipart é derivado da extensão (`.ogg → audio/ogg`, `.mp3 → audio/mpeg`, `.m4a → audio/mp4`, `.wav → audio/wav`; default `application/octet-stream`).
- O **`original_filename`** é user input — guardado **sanitizado** (`Path.basename` + truncado a 255 chars) e **nunca usado como path** (o path temp usa só UUID + extensão). Ver §7.
- **Descarte (best-effort):** o worker apaga o binário (`File.rm/1`, ignora erro se já sumiu) assim que a transcrição é gravada com sucesso **ou** no último attempt de erro da etapa de transcrição. A etapa 2 (sugestão) não precisa do binário. Não é atômico com o DB — um crash entre `save_transcription` e `File.rm` deixa o binário órfão (ver §12); aceitável pois o áudio sem registro é inútil.

---

## 6. Worker — `TranscribeAndSuggestWorker`

`use Oban.Worker, queue: :ai, max_attempts: 3`. `perform(%Oban.Job{args: %{"audio_message_id" => id, "user_id" => uid, "tenant_id" => tid, "audio_path" => path}, attempt: a, max_attempts: max})`:

1. Reconstrói o scope do dono via `with_auth_bypass` + valida `%User{tenant_id: ^tid}`; inexistente → `{:discard, :not_found}`.
2. Carrega `AudioMessages.get_audio_message(scope, id)`; `nil` → `{:discard, :not_found}`.
3. **Idempotência (at-least-once):** `status in [:done, :error]` → `:ok` (no-op). Reexecução de um job já concluído **ou** já marcado `error` não re-processa nem re-chama `fail` (importante pro caso `error` + `transcription` nil: sem isso, a reexecução cairia de novo na guarda de arquivo ausente). Um retry **legítimo** vem via `retry_suggestion`, que muda o status pra `:suggesting` **antes** de re-enfileirar — então o job de retry não bate nesta guarda.
4. **Etapa 1 — transcrição** (só se `transcription` está `nil`):
   - **Guarda defensiva (binário sumiu):** se `audio_path` é `nil` **ou** `not File.exists?(audio_path)` — o tmp foi limpo, o nó reiniciou, ou é um job órfão sem transcrição — então a etapa 1 é **irreversível** (o áudio não volta): `fail(scope, msg, :audio_file_missing)` + broadcast → `:ok` (terminal, **sem retry** — re-tentar não recupera o arquivo).
   - Senão: `mark_transcribing` + broadcast; `AI.transcribe(path)`:
     - `{:ok, %{text, provider, model}}` → `save_transcription(scope, msg, text, "#{provider}:#{model}")` (status `:suggesting`) + broadcast; **`File.rm(path)`** (áudio descartado; best-effort, ignora erro).
     - `{:error, _}` com `a < max` → `{:error, reason}` (retry; binário preservado pro retry).
     - `{:error, reason}` com `a >= max` → `fail(scope, msg, reason)` + **`File.rm(path)`** + broadcast → `:ok`.
   - Se já havia `transcription` (retry da etapa 2), pula a etapa 1 inteira (e nunca toca no `audio_path`).
5. **Etapa 2 — sugestão** (transcrição presente, status ≠ done):
   - Recarrega a msg (pega a `transcription` salva), monta `input = %{patient: Patients.get_patient!(scope, msg.patient_id), last_record: List.first(Records.recent_done_records(scope, %{id: msg.patient_id}, 1)), transcription: msg.transcription, tone: msg.tone}` (`last_record` pode ser `nil`).
   - `AI.generate_reply(input)`:
     - `{:ok, %{content, provider, model}}` → `complete(scope, msg, content, "#{provider}:#{model}")` (status `:done`, grava `reply_model_used`) + broadcast → `:ok`.
     - `{:error, _}` com `a < max` → `{:error, reason}` (retry — **não re-transcreve**, a transcrição já está salva).
     - `{:error, reason}` com `a >= max` → `fail(scope, msg, reason)` + broadcast → `:ok`.

A IA (transcrição e chat) roda **fora de transação**. O worker chama contexts sequencialmente (cada um abre a sua transação) — sem aninhamento. **Limpeza best-effort:** o `File.rm` após salvar a transcrição é o ponto canônico de descarte; um crash entre o `save_transcription` e o `File.rm` deixaria o binário órfão (ver §12) — aceitável, pois o áudio sem o registro é inútil e o tmp é volátil.

---

## 7. Context — `Ravanshenasi.AudioMessages`

```
create_audio_message(scope, patient, %{audio_path, original_filename, tone})
    # 1) clinical_access?; 2) recarrega o paciente escopado (nil → {:error, :unauthorized});
    # 3) valida tone na whitelist; 4) SANITIZA original_filename (Path.basename + trunca p/ 255 chars —
    #    é user input, pode conter dado clínico; NUNCA usado pra path); 5) insere status=pending +
    #    Oban.insert! (atômico via transact_tenant).
get_audio_message(scope, id) / get_audio_message!(scope, id)
list_audio_messages(scope, %{id: patient_id})   # histórico — query escopada por tenant_id+user_id+patient_id
update_suggested_response(scope, %{id}, text)    # edição do profissional (só quando :done); recarga escopada
retry_suggestion(scope, %{id})                   # SÓ quando :error E transcription presente: status→:suggesting +
                                                 #   re-enfileira (audio_path: nil — a etapa 1 é pulada). Erro de
                                                 #   transcrição (sem transcription) NÃO é retryável: exige novo upload.
# internos (worker, scope reconstruído) — recarregam, idempotentes:
mark_transcribing(scope, msg)
save_transcription(scope, msg, text, transcription_model)  # grava transcription + transcription_model + status
                                                 #   :suggesting; no-op se já há transcription
complete(scope, msg, suggested_response, reply_model)      # grava resposta + reply_model_used + status :done;
                                                 #   no-op se já :done
fail(scope, msg, reason)                          # status :error + error_reason (inspect); no-op se já :done
subscribe(audio_message_id) / broadcast(msg)      # tópico "audio:<id>"
job_args(msg, audio_path)                         # %{audio_message_id, user_id, tenant_id, audio_path}  (audio_path
                                                 #   pode ser nil no retry_suggestion)
```

- **Idempotência:** `mark_transcribing` não regride `done`/`error`; `save_transcription` é no-op se já há transcrição; `complete`/`fail` são no-op se já `:done`. Espelha o padrão da Fatia 3.
- **`create_audio_message`** opera no paciente **recarregado** (não no struct do caller). `tone` é validado contra a whitelist `[:empathetic, :informative, :encouraging]` no changeset (`Ecto.Enum`) — **nunca `String.to_atom`** em input externo.
- **Reads E writes escopam por id** (`list_audio_messages`/`update_suggested_response` não vazam struct alheio).

---

## 8. Autorização

`clinical_access?` + dono (`user_id`) em **tudo** (create, get/list, update). Admin de clínica → `{:error, :unauthorized}`. Toda função — read, list e write — escopa/recarrega por query escopada. RLS por `tenant_id` é a rede entre tenants.

---

## 9. Erros e edge cases

| Situação | Comportamento |
|---|---|
| Upload >25MB ou extensão fora de `.ogg/.mp3/.m4a/.wav` | barrado em `allow_upload` (borda); não cria registro |
| Binário sumiu antes da etapa 1 (tmp limpo, restart, job órfão) | `status :error` `:audio_file_missing` **terminal, sem retry** (re-tentar não recupera o arquivo); UI orienta novo upload |
| Whisper retorna texto vazio | `{:error, {:empty_transcription, _}}` → retry; esgotado → `status :error` |
| Whisper falha / áudio ilegível (todos providers) | retry; esgotado → `status :error` + `error_reason` + aviso na UI; binário apagado |
| Sugestão (chat) falha | retry **sem re-transcrever** (transcrição preservada); esgotado → `status :error` |
| `create`/`update` de paciente/áudio alheio ou inexistente | recarga escopada → `{:error, :unauthorized}` |
| `audio_message` deletado antes do job | `{:discard, :not_found}` |
| Reexecução de job já `:done` | no-op (não re-transcreve, não duplica) |
| Nó cai entre upload e transcrição | binário órfão no tmp (raro; sem sweeper no MVP — ver §12) |

---

## 10. Real-time (PubSub)

Tópico `"audio:<id>"`. Worker faz broadcast em `transcribing`/`suggesting`/`done`/`error`. A `AudioLive` assina o áudio corrente e atualiza: `pending`/`transcribing` → "Transcrevendo…"; `suggesting` → "Gerando resposta…" (já mostra a transcrição); `done` → transcrição + resposta sugerida (campo editável + copiar); `error` → mensagem + "tentar de novo" (re-enfileira **a mesma** msg se ainda tiver transcrição; se não, exige novo upload).

---

## 11. UI — `AudioLive` (rota `/pacientes/:id/audios`)

- **Upload:** `live_file_input` + seletor de **tom** (3 opções) + botão "Transcrever e sugerir". Estados de upload (progresso, erro de validação).
- **Lista (histórico):** áudios do paciente (mais recentes primeiro) via `list_audio_messages`, com `original_filename`, status, transcrição e resposta.
- **Item `done`:** mostra a transcrição (read-only) e a **resposta sugerida em `<textarea>` editável** + botão **Copiar** (JS hook `navigator.clipboard`) + salvar edição (`update_suggested_response`).
- **Item `error`:** mensagem. Se **a transcrição já existe** (erro foi na etapa 2) → botão **"Tentar de novo"** (`retry_suggestion`, refaz só a etapa 2). Se **não há transcrição** (erro na transcrição, binário já descartado) → orientação pra **fazer um novo upload** (sem botão de retry).
- IDs estáveis pros testes (`#audio-upload-form`, `#audio-<id>`, `#transcription-<id>`, `#suggested-response-<id>`, `#copy-response-<id>`, `#retry-audio-<id>`).
- **Rota dentro do `live_session :require_clinical`** (mesmo bloco de pacientes/sessões), que aplica `on_mount [{UserAuth, :require_authenticated}, {UserAuth, :require_clinical_access}]`. **Áudio é dado clínico**: o gate de rota garante que **admin de clínica (que não atende paciente) é barrado já no mount** (redirect), além do `clinical_access?` no context. NÃO colocar no `live_session :require_authenticated_user` (esse deixaria o admin entrar).

---

## 12. Limitações assumidas (MVP)

- **Single-node:** o binário temporário fica em disco local (`System.tmp_dir!`); o Oban roda no mesmo nó. Multi-node exigiria storage compartilhado (S3/MinIO) — fora do escopo.
- **Binário órfão** se o nó cair (a) entre upload e transcrição, ou (b) entre `save_transcription` e `File.rm` — sem sweeper periódico no MVP (arquivo temp pequeno e raro; descarte é best-effort, não atômico com o DB).
- `File.read/1` carrega o áudio inteiro em memória pro multipart (aceitável ≤25MB; streaming fica pra depois).

---

## 13. Estratégia de testes

`async: false` onde toca `transact_tenant`/bypass. Oban `:manual` (`assert_enqueued`/`perform_job`). Stub de transcrição e de chat config-driven.

- **`AI.Transcriber.Stub`** / **`AI.Transcriber.OpenAI`**: stub ok/erro; OpenAI client com `Req.Test` plug (multipart) → `{:ok, text}` / `{:error, {:http_error, _, _}}`; **arquivo ausente → `{:error, {:audio_unreadable, _}}`** (não levanta); **texto vazio → `{:error, {:empty_transcription, _}}`**.
- **`AI.transcribe/1`**: fallback (1º provider falha → 2º ok); todos falham → `{:error, {:all_providers_failed, _}}`; sucesso devolve `%{text, provider, model}`.
- **`AI.Prompts.whatsapp_reply_messages/1`**: system muda por tom; user contém transcrição + perfil.
- **`AudioMessages`**: `create_audio_message` cria `pending` + `assert_enqueued`; isolamento entre profissionais (msg de A invisível pra B do mesmo tenant, incl. `list`); `update_suggested_response` muda texto; alheio → `:unauthorized`. Tom inválido → changeset inválido.
- **`TranscribeAndSuggestWorker`** (`perform_job`): stub ok nas 2 etapas → `done` + transcrição + resposta + `transcription_model`/`reply_model_used` gravados + **binário apagado**; **`audio_path` inexistente (binário sumiu) → `error :audio_file_missing` terminal** (retorna `:ok`, não re-tenta); falha na transcrição no último attempt → `error`; falha na sugestão com transcrição salva → retry **não re-transcreve**; reexecução de `done` → no-op.
- **`AudioLive`**: upload (com stub) → "Transcrevendo"; broadcast `done` → transcrição + resposta editável; salvar edição persiste; IDs estáveis + `element`/`has_element?`. Teste de upload usa `file_input`/`render_upload` do `Phoenix.LiveViewTest`.
- **Gate de rota (não só context):** `live(conn, ~p"/pacientes/#{p}/audios")` com **clinic admin** → `{:error, {:redirect, _}}` (barrado pelo `live_session :require_clinical`). Protege contra registrar a rota no `live_session` errado.

---

## 14. Estrutura de arquivos

```
lib/ravanshenasi/
  audio_messages.ex
  audio_messages/audio_message.ex
  audio_messages/transcribe_and_suggest_worker.ex   # Oban.Worker
  ai.ex                                              # +transcribe/1, +generate_reply/1
  ai/transcriber.ex                                  # behaviour
  ai/transcriber/open_ai.ex                          # multipart (OpenAI/NIM), via req
  ai/transcriber/stub.ex                             # testes
  ai/prompts.ex                                      # +whatsapp_reply_messages/1
lib/ravanshenasi_web/live/audio_live/
  index.ex                                           # upload + lista + edição/cópia + PubSub
priv/repo/migrations/
  *_create_audio_messages.exs                        # FK composta (patient/user) + RLS + unique (id,tenant_id,user_id)
config/{config,runtime,test}.exs                     # +transcription: order/providers
lib/ravanshenasi_web/router.ex                       # +live "/pacientes/:patient_id/audios" no live_session :require_clinical
```

---

## 15. Fora de escopo (fatias futuras)

- Integração real com a API do WhatsApp (aqui é upload manual).
- Reter/reouvir o áudio; reprocessar a partir do binário (ele é descartado).
- Transcrição via NIM gRPC/Riva (só endpoints OpenAI-compatible nesta fatia).
- Múltiplas sugestões por áudio; tradução; diarização (quem fala).
- Storage compartilhado multi-node; streaming de upload; sweeper de órfãos.
- Dashboard (Fatia 5).

---

## 16. Definition of Done

- [ ] `AI.Transcriber` (behaviour) + `Transcriber.OpenAI` (multipart, OpenAI/NIM-compatible, **`File.read/1` sem levantar**, **rejeita texto vazio**) + `Transcriber.Stub`; `AI.transcribe/1` com `order`/`providers`/fallback → `{:ok, %{text, provider, model}}` (config `transcription:`).
- [ ] `AI.generate_reply/1` + `Prompts.whatsapp_reply_messages/1` (3 tons; `last_record` nil tolerado).
- [ ] Migration `audio_messages`: colunas incl. `transcription_model` + `reply_model_used`; FK composta `(…, tenant_id, user_id)` (incl. `patient_id` amarrando paciente↔dono) + RLS + unique `(id, tenant_id, user_id)`.
- [ ] `AudioMessages`: `create_audio_message` atômico (`pending` + `assert_enqueued`), tom na whitelist, **`original_filename` sanitizado**; `update_suggested_response`; `retry_suggestion` (só `:error` + transcrição presente); **reads e writes** escopam/recarregam por id; isolamento entre profissionais testado (incl. `list`).
- [ ] `TranscribeAndSuggestWorker`: scope reconstruído (valida user↔tenant), 2 etapas idempotentes, IA fora de transação, **guarda `:audio_file_missing` terminal** (binário sumiu → erro sem retry), grava `transcription_model`/`reply_model_used`, **binário descartado** após transcrição (sucesso ou erro-final), retry da etapa 2 não re-transcreve, `discard` se não achar.
- [ ] Upload: `allow_upload` (≤25MB, extensões), `consume_uploaded_entry` move pra tmp, content_type por extensão.
- [ ] PubSub: `AudioLive` "Transcrevendo"/"Gerando resposta"/resposta editável + copiar / erro (+tentar de novo); IDs estáveis nos testes.
- [ ] Autorização: rota no `live_session :require_clinical` (gate `on_mount :require_clinical_access` — admin de clínica barrado no mount, testado via `live/2`); `clinical_access?` no context; isolamento entre profissionais.
- [ ] `mix precommit` verde; testes não batem na API real (stub).
