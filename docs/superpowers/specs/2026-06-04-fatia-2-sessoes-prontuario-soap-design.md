# Fatia 2 — Sessões + Prontuário SOAP (IA)

**Projeto:** Ravanshenasi (PsiCare) — SaaS de psicologia
**Data:** 2026-06-04
**Status:** Spec aprovado, pronto pra virar plano de implementação
**Depende de:** Fatia 0 (Fundação) + Fatia 1 (Pacientes + Linhas de Pensamento), ambas implementadas.
**Stack:** Phoenix 1.8.7 + LiveView 1.1 + Ecto + TimescaleDB HA pg17 + Oban + `req`

---

## 1. Contexto e objetivo

Terceira fatia. Sobre Pacientes + Linhas de Pensamento (Fatia 1), adiciona o **registro de sessões** terapêuticas e a **geração automática de prontuário SOAP por IA** ao finalizar uma sessão. É a **primeira fatia com IA e jobs assíncronos** — introduz o subsistema de IA (provider-agnóstico, protocolo OpenAI) e o Oban.

Fluxo central: o profissional registra notas de uma sessão (`draft`); ao **finalizar**, dispara-se um job assíncrono que chama um LLM para gerar o prontuário no formato **SOAP** (Subjetivo, Objetivo, Avaliação, Plano) a partir do perfil do paciente, das linhas de pensamento ativas e das notas; o resultado aparece em tempo real e fica editável/revisável pelo profissional.

### API herdada (usar como está)
- `Ravanshenasi.Accounts.Scope` (`%Scope{user, tenant}`, `clinical_access?/1`, `admin?/1`).
- `Ravanshenasi.Repo.transact_tenant(scope, fn)` (resultado cru; reset GUC no sucesso), `with_auth_bypass/1`, `with_registration_bypass_multi/1`.
- `Ravanshenasi.RLS.enable_tenant_rls(tabela)` (FORCE RLS fail-closed por `tenant_id`).
- `Ravanshenasi.Patients`: `get_patient!/2`, `list_patient_frameworks/2` (linhas ativas do paciente).
- Padrão de isolamento: **RLS por `tenant_id` + scope por `user_id` + FK composta `(…, tenant_id)`** (ver specs das Fatias 0 e 1). **Regra crítica (lição da Fatia 1, reforçada na §7):** RLS de tenant **NÃO** isola entre profissionais do mesmo tenant; toda função que recebe um struct (`patient`/`session`/`record`) **não confia nele** — revalida `tenant_id`/`user_id` contra o scope (ou recarrega por query escopada) antes de operar.

---

## 2. Decisões de arquitetura (aprovadas)

| # | Decisão | Escolha | Justificativa |
|---|---|---|---|
| F2-D1 | Escopo | Sessões **+** Prontuário SOAP (IA) juntos | Record é gerado da sessão; fatia completa do roadmap |
| F2-D2 | Cliente IA | Behaviour `AI.Client` + **stub via config** (sem dep nova) | Boundary de domínio testável sem rede/custo |
| F2-D3 | Protocolo | **OpenAI** (`chat/completions`) — OpenAI, NVIDIA NIM e compatíveis | Um client serve todos; só muda config |
| F2-D4 | Providers | **Múltiplos registrados + seleção/fallback** (ordem configurável) | Resiliência (tenta NIM → cai pra OpenAI) |
| F2-D5 | Assíncrono | **Oban** (dep + migration `oban_jobs` + retry 3x) | Persistente, sobrevive a restart, observável |
| F2-D6 | Real-time | **Phoenix PubSub** | UI atualiza sozinha quando o record fica `done`/`error` |
| F2-D7 | Isolamento | RLS por `tenant_id` + scope `user_id` + FK composta | Padrão consolidado das Fatias 0/1 |
| F2-D8 | Acesso no job | Job **reconstrói o scope do dono** (via `with_auth_bypass`) e usa os contexts scoped | Reusa o isolamento, não fura RLS |

---

## 3. Modelo de dados

Ambas as tabelas: `:binary_id` PK, RLS por `tenant_id`, FK composta `(…, tenant_id)`, acessadas via `transact_tenant`.

### `sessions` (scope: `tenant_id` + `user_id` do dono)
| Coluna | Tipo | Notas |
|---|---|---|
| `id` | binary_id | PK |
| `tenant_id` | binary_id | FK → tenants, NOT NULL |
| `user_id` | binary_id | FK → users (composta `(user_id, tenant_id)`), NOT NULL |
| `patient_id` | binary_id | FK → patients (composta `(patient_id, tenant_id)`), NOT NULL |
| `date` | utc_datetime | data/hora da sessão |
| `duration_minutes` | integer | nullable |
| `notes` | text | notas do profissional |
| `status` | enum (`draft`, `finalized`) | default `draft` |
| `inserted_at`/`updated_at` | utc_datetime | |

Índices: `(tenant_id, user_id)`, `(tenant_id, patient_id)`, `(tenant_id, user_id, status)`, unique `(id, tenant_id, user_id)` e unique `(id, patient_id)` (alvos das FKs compostas do record).

### `records` (prontuário — scope: `tenant_id` + `user_id`)
| Coluna | Tipo | Notas |
|---|---|---|
| `id` | binary_id | PK |
| `tenant_id` | binary_id | FK → tenants, NOT NULL |
| `user_id` | binary_id | parte da FK composta **`(session_id, tenant_id, user_id) → sessions(id, tenant_id, user_id)`** — amarra dono+tenant ao da sessão, NOT NULL |
| `session_id` | binary_id | FK → sessions, NOT NULL, **unique** |
| `patient_id` | binary_id | parte da FK composta **`(session_id, patient_id) → sessions(id, patient_id)`** — amarra o paciente ao da sessão, NOT NULL |
| `content` | text | prontuário SOAP gerado (editável na revisão) |
| `reviewed` | boolean | default `false` |
| `generation_status` | enum (`pending`, `generating`, `done`, `error`) | default `pending` |
| `model_used` | string | provider **e** modelo que geraram, formato `"provider:model"` (ex.: `nim:meta/llama-3.1-70b`) — auditoria, nullable |
| `error_reason` | string | preenchido quando `error`, nullable |
| `inserted_at`/`updated_at` | utc_datetime | |

Unique `(session_id)` — **um record por sessão**. Índices `(tenant_id, user_id)`, `(tenant_id, patient_id)`.

> **Integridade record↔session (derivar, não copiar do caller):** no `finalize`, o record **deriva** `tenant_id`, `user_id` e `patient_id` lendo da própria `session` — nunca de parâmetros do chamador. **Duas FKs compostas** são a rede de segurança no banco: `(session_id, tenant_id, user_id) → sessions(id, tenant_id, user_id)` e `(session_id, patient_id) → sessions(id, patient_id)`. Juntas tornam **impossível** um record divergir do tenant/dono/paciente da sua sessão — inclusive o `user_id`, que é o campo que isola profissionais (constraint, não só a derivação no código).

> `oban_jobs`: tabela do Oban (migration própria do Oban). **Sem RLS** (infra, não dado clínico) — `Oban.insert` roda dentro do `transact_tenant` da finalização sem problema (a tabela não tem policy).

---

## 4. Subsistema de IA (provider-agnóstico, protocolo OpenAI)

```
lib/ravanshenasi/ai.ex                 # Ravanshenasi.AI — fachada: registry + fallback + generate_soap/1
lib/ravanshenasi/ai/client.ex          # behaviour
lib/ravanshenasi/ai/client/open_ai.ex  # impl OpenAI-protocol (req)
lib/ravanshenasi/ai/client/stub.ex     # impl de teste (sem rede)
lib/ravanshenasi/ai/prompts.ex         # monta system + user prompt do SOAP
```

### Behaviour `Ravanshenasi.AI.Client`
```elixir
@callback chat(provider_cfg :: map(), messages :: [map()], opts :: keyword()) ::
            {:ok, content :: String.t()} | {:error, reason :: term()}
```
- `messages`: lista `%{role: "system"|"user", content: ...}` (formato OpenAI chat).
- **`Client.OpenAI`**: `POST #{base_url}/chat/completions` via `req`, body `%{model, messages, temperature}`, header `Authorization: Bearer #{api_key}`; parseia `choices |> hd() |> get_in(["message", "content"])`. Erro de rede/timeout/HTTP ≥ 400 / corpo inesperado / `content` vazio → `{:error, reason}`.
- **`Client.Stub`**: retorna `{:ok, "<SOAP fake>"}` (ou `{:error, …}` configurável) — usado em `test`.

### Fachada `Ravanshenasi.AI`
- Config: `config :ravanshenasi, Ravanshenasi.AI, order: [:nim, :openai], providers: %{nim: %{client: Client.OpenAI, base_url, api_key, model}, openai: %{…}}`. Em `test`: `order: [:stub], providers: %{stub: %{client: Client.Stub}}`.
- `generate_soap(input)`:
  1. `Prompts.soap_messages(input)` → `messages`.
  2. itera `order`; para cada provider, `cfg.client.chat(cfg, messages, [])`.
  3. primeiro `{:ok, content}` (com `content` não-vazio) → `{:ok, %{content: content, provider: name, model: cfg.model}}`.
  4. todos falham → `{:error, {:all_providers_failed, reasons}}`.
- **Fallback** é só essa iteração na `order` — sem dep nova, configurável.

### Prompt SOAP (`AI.Prompts`, base no `AI_DESIGN.md`)
- **system** (fixo): assistente clínico em psicologia; gera prontuário SOAP a partir das notas; linguagem clínica e de **hipótese** ("sugere", "indica", "observa-se"); **nunca** inventa informação fora das notas; responde **apenas** o prontuário.
- **user**: perfil do paciente (nome, idade derivada de `birth_date`, queixa, histórico) + **linhas de pensamento ativas** (`Patients.list_patient_frameworks` → nome+descrição) + **últimas 3 sessões finalizadas ANTERIORES** (data + notas) + notas da **sessão atual** → pede S/O/A/P. As "anteriores" usam `recent_finalized(scope, patient, session.id)` **excluindo a sessão atual** — que já está `finalized` quando o job roda, então sem o exclude ela apareceria duas vezes.

---

## 5. Oban

- Dep `oban` + migration que cria `oban_jobs` (gerada pelo Oban) + `Oban` no supervision tree de `application.ex` (`queues: [ai: 5]`, repo).
- Worker `Ravanshenasi.Records.GenerateSoapWorker` (`use Oban.Worker, queue: :ai, max_attempts: 3`).
- `perform(%Oban.Job{args: %{"record_id" => id, "user_id" => uid, "tenant_id" => tid}})`:
  1. Reconstrói o scope do dono: carrega `user` + `tenant` **por id** via `with_auth_bypass`; `scope = Scope.for_user(user) |> put_tenant(tenant)`. User/tenant inexistente → `{:discard, :not_found}`.
  2. **Carrega o record via API escopada** `Records.get_record(scope, record_id)` — a query é escopada por `tenant_id`+`user_id`, então isso **valida** que o record pertence ao dono do job (não confia nos args além do id). `nil` (record/sessão deletado, ou não é do dono) → `{:discard, :not_found}`.
  3. `Records.mark_generating(scope, record)` (transação curta) + broadcast.
  4. Monta `input` via contexts scoped (transações curtas): paciente (`Patients.get_patient!`), frameworks ativos (`Patients.list_patient_frameworks`), **3 sessões finalizadas anteriores** (`Sessions.recent_finalized(scope, patient, record.session_id)`), notas da sessão atual.
  5. `AI.generate_soap(input)` — **fora de qualquer transação** (não segurar conexão/GUC durante a chamada HTTP lenta à IA).
     - `{:ok, %{content, model, provider}}` → `Records.complete(scope, record, content, "#{provider}:#{model}")` (status `done`, grava `model_used` = `provider:model` pra auditoria) + broadcast → retorna `:ok`.
     - `{:error, reason}`: se `job.attempt < job.max_attempts` → retorna `{:error, reason}` para o Oban **re-tentar** (record continua `generating`); no **último** attempt (`job.attempt >= job.max_attempts`) → `Records.fail(scope, record, reason)` (status `error` + `error_reason`) + broadcast → retorna `:ok` (não re-tenta mais).
  - Record inexistente (sessão/record deletado) → `{:discard, :not_found}` (não re-tenta).

---

## 6. Contexts (API)

### `Ravanshenasi.Sessions`
```
list_sessions(scope, patient)              # sessões do paciente (do dono)
get_session(scope, id) / get_session!(scope, id)
create_session(scope, patient, attrs)      # status :draft
update_session(scope, session, attrs)      # só se :draft; senão {:error, :finalized}
finalize_session(scope, session)           # :draft -> :finalized + cria record(pending) + enfileira job (atômico)
change_session(session, attrs \\ %{})
recent_finalized(scope, patient, exclude_session_id, limit \\ 3)  # 3 últimas finalizadas ANTERIORES (exclui a sessão atual — senão duplica no prompt)
```
- `finalize_session` (autorizado por `clinical_access?` + `owns?`): dentro de `transact_tenant` (transação única), na ordem:
  1. **UPDATE condicional** — `Repo.update_all(from s in Session, where: s.id == ^id and s.tenant_id == ^tid and s.user_id == ^uid and s.status == :draft, set: [status: :finalized, updated_at: ...])`. Se afetar **0 linhas** (já `finalized`, ou perdeu a corrida com uma requisição concorrente na mesma sessão `draft`) → `Repo.rollback(:already_finalized)` → `{:error, :already_finalized}`, sem criar record nem job.
  2. afetou **1 linha** → `Repo.insert!` record (`pending`, com `tenant_id`/`user_id`/`patient_id` **derivados da session**) → `Oban.insert!(GenerateSoapWorker.new(%{record_id, user_id, tenant_id}))`.
  - Qualquer raise reverte tudo (nada finalizado, nenhum job órfão). O `unique(records.session_id)` é a rede de segurança contra duplo-record. O UPDATE condicional **serializa** finalizações simultâneas: só uma transação enxerga `status=:draft` e vence; a outra vê 0 linhas. **Não** aninhar `Ecto.Multi`/`Repo.transaction` (evita savepoint redundante).
- Autorização: `clinical_access?` + `owns?` (dono) em tudo.

### `Ravanshenasi.Records`
```
get_record(scope, id) / get_record_for_session(scope, session)
update_record(scope, record, attrs)        # editar content (revisão) — só quando :done
mark_reviewed(scope, record)
list_records(scope, patient)               # histórico
retry_generation(scope, record)            # "tentar de novo": SÓ quando status ∈ [:error] →
                                           # volta a :pending (limpa error_reason) + re-enfileira o MESMO record;
                                           # outros status → {:error, :not_retryable}
# internos (chamados pelo worker, scope reconstruído):
mark_generating/complete/fail(scope, record, ...)
broadcast(record)                          # Phoenix.PubSub no tópico "record:<id>"
```

---

## 7. Autorização

`clinical_access?` (therapist ou solo-admin) **+** `owns?` (dono via `user_id`) em **todo** acesso a sessões e records. Admin de clínica → `{:error, :unauthorized}` (não atende). Rotas LiveView sob o `on_mount :require_clinical_access` (já existe na Fatia 1). RLS por `tenant_id` é a rede entre tenants; o scope `user_id` isola entre profissionais.

**Structs não confiáveis (lição da Fatia 1):** toda função que recebe `session`/`record`/`patient` **não confia no struct** do caller — revalida `tenant_id`/`user_id` via `owns?` (ou recarrega por query escopada) antes de operar. Ex.: `update_session(scope, session, attrs)` confirma `owns?(scope, session)`; o worker recarrega o record por `get_record(scope, id)` em vez de usar um struct cru.

---

## 8. Erros e edge cases

| Situação | Comportamento |
|---|---|
| Finalizar sessão já `finalized` **ou corrida** de 2 requisições na mesma sessão `draft` | UPDATE condicional `WHERE status=:draft`: o vencedor finaliza + enfileira; o perdedor afeta 0 linhas → `{:error, :already_finalized}` (sem record/job duplicado; `unique(session_id)` como rede) |
| Editar/atualizar sessão `finalized` | `{:error, :finalized}` |
| `retry_generation` em record com status ≠ `:error` | `{:error, :not_retryable}` |
| Todos os providers falham (após `max_attempts`) | record `error` + `error_reason`; UI mostra erro + opção de regenerar |
| Provider retorna `content` vazio/HTTP erro | `{:error, …}` daquele provider → tenta o próximo; se todos, retry do Oban |
| Job não acha record/sessão (deletado) | `{:discard, :not_found}` (não re-tenta) |
| Acesso a sessão/record de outro profissional | `nil`/`{:error, :unauthorized}` (scope + RLS) |
| Config de provider ausente/sem chave | erro claro logado; provider pulado no fallback |

---

## 9. Real-time (PubSub)

- Tópico `"record:<record_id>"` (e/ou `"patient:<patient_id>:records"`).
- Worker faz `Phoenix.PubSub.broadcast` ao mudar para `generating`/`done`/`error`.
- A LiveView da sessão/perfil assina no `mount` (se `connected?`) e atualiza o assign do record + re-render. Estados: `pending`/`generating` → "gerando…"; `done` → mostra SOAP + ação revisar; `error` → mensagem + "tentar de novo".

---

## 10. Estratégia de testes

`async: false` em tudo que toca `transact_tenant`/bypass (race do Sandbox). Oban em modo de teste (`testing: :manual` → `assert_enqueued` + `Oban.Testing.perform_job`).

- **Sessions**: CRUD scoped (isolamento user/tenant; admin de clínica barrado); `update` em `finalized` bloqueado; `recent_finalized` retorna as 3 últimas finalizadas **e EXCLUI a sessão passada em `exclude_session_id`** (teste de regressão: finalizar a sessão e conferir que ela **não** entra na própria lista de "anteriores").
- **finalize_session**: cria record `pending` + **`assert_enqueued` GenerateSoapWorker**; finalizar 2x → `{:error, :already_finalized}` (sem segundo job).
- **GenerateSoapWorker** (`perform_job`): com `Client.Stub` `{:ok}` → record `done` + `content` + `model_used` + broadcast recebido; com stub `{:error}` em todos attempts → record `error` + `error_reason`.
- **AI fallback**: `order: [:bad, :good]`; `bad` stub `{:error}`, `good` stub `{:ok}` → `generate_soap` retorna do `good` com `provider: :good`.
- **AI.Prompts**: as `messages` contêm perfil, as linhas de pensamento ativas, as 3 sessões **anteriores** e as notas da sessão atual — e **não duplicam a sessão atual** (cobre o bug do `exclude_session_id`).
- **Client.OpenAI**: monta o request certo (método/URL/headers/body) e parseia `choices[0].message.content` — testado com `Req.Test` (stub HTTP), sem rede real.
- **LiveView**: finalizar mostra "gerando"; um broadcast `done` atualiza pra mostrar o SOAP; revisar edita o content.

---

## 11. Estrutura de arquivos

```
lib/ravanshenasi/
  sessions.ex
  sessions/session.ex
  records.ex
  records/record.ex
  records/generate_soap_worker.ex     # Oban.Worker
  ai.ex                               # Ravanshenasi.AI (fachada + fallback)
  ai/client.ex                        # behaviour
  ai/client/open_ai.ex                # impl OpenAI-protocol (req)
  ai/client/stub.ex                   # impl de teste
  ai/prompts.ex                       # build do prompt SOAP
  application.ex                      # + Oban no supervision tree
lib/ravanshenasi_web/live/
  session_live/{index,show,form}.ex   # sessões do paciente + finalizar + prontuário/revisão
priv/repo/migrations/
  *_add_oban_jobs_table.exs           # Oban.Migration
  *_create_sessions.exs               # + FK composta + RLS
  *_create_records.exs                # + FK composta + RLS + unique(session_id)
config/
  config.exs   # Oban (repo, queues), Ravanshenasi.AI (order, providers via env em runtime.exs)
  test.exs     # Oban testing :manual; AI order: [:stub]
  runtime.exs  # AI providers via env (AI_*_BASE_URL/API_KEY/MODEL)
# estende: router.ex (rotas de sessão sob require_clinical_access)
```

---

## 12. Fora de escopo (fatias futuras)

- Sugestão de abordagens terapêuticas (Fatia 3), áudio/Whisper (Fatia 4), dashboard (Fatia 5).
- Streaming de tokens da IA (resposta chega inteira; sem SSE no MVP).
- Provider/modelo por tenant (decidido: registry global com fallback; por-tenant é escopo maior).
- Regeneração automática/versionamento de prontuários (há 1 record por sessão; "tentar de novo" re-enfileira o mesmo record).
- Agendamento de sessões / calendário.

---

## 13. Definition of Done

- [ ] Migrations: `oban_jobs`, `sessions`, `records` (FK composta + `enable_tenant_rls`); unique `(session_id)`.
- [ ] CRUD de sessões scoped; `draft→finalized`; editar `finalized` bloqueado.
- [ ] `finalize_session` atômico via UPDATE condicional (`WHERE status=:draft`): finaliza + record `pending` + job (`assert_enqueued`); 2x ou corrida → `{:error, :already_finalized}` (sem duplicar; teste de concorrência).
- [ ] **Integridade record↔session**: FKs compostas `(session_id, tenant_id, user_id) → sessions(id, tenant_id, user_id)` **e** `(session_id, patient_id) → sessions(id, patient_id)`; record **deriva** tenant/user/patient da session (não do caller) — o banco recusa drift, inclusive em `user_id`.
- [ ] Subsistema IA: behaviour `AI.Client`, impl OpenAI-protocol (req), stub; `AI.generate_soap` com **fallback** na `order`; prompt SOAP com perfil + frameworks + 3 sessões anteriores (**exclui a atual**) + notas.
- [ ] `GenerateSoapWorker`: carrega/valida o record por API escopada; `done` no sucesso (content + `model_used` = `provider:model`), `error`+`error_reason` no último attempt; chamada IA **fora** de transação; reconstrói scope sem furar RLS.
- [ ] `retry_generation` re-enfileira só de `:error`; PubSub atualiza `gerando → pronto/erro` em real-time; revisão edita o content + `reviewed`.
- [ ] Autorização: admin de clínica sem acesso; isolamento entre profissionais (scope `user_id`) testado; structs revalidados nos contexts.
- [ ] `mix precommit` verde (compile, format, credo --strict, test); testes não batem na API real (stub).
