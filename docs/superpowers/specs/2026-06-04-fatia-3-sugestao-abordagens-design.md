# Fatia 3 — Sugestão de Abordagens Terapêuticas (IA)

**Projeto:** Ravanshenasi (PsiCare) — SaaS de psicologia
**Data:** 2026-06-04
**Status:** Spec aprovado, pronto pra virar plano de implementação
**Depende de:** Fatia 0 (Fundação), Fatia 1 (Pacientes + Linhas), Fatia 2 (Sessões + Prontuário + subsistema de IA/Oban). Todas implementadas.
**Stack:** Phoenix 1.8.7 + LiveView 1.1 + Ecto + TimescaleDB pg17 + Oban + `req`

---

## 1. Contexto e objetivo

Quarta fatia. A partir do perfil do paciente, das **linhas de pensamento ativas** e do **histórico de prontuários**, um LLM sugere **2 a 4 abordagens** para o próximo atendimento, exibidas em cards que o profissional pode salvar ou descartar. Reusa quase toda a infra da Fatia 2 (subsistema de IA provider-agnóstico, Oban, PubSub, padrão scope/RLS); o que muda é que a **saída é JSON estruturado** (não texto livre), então precisa parse + validação.

### API herdada (usar como está)
- `Ravanshenasi.AI.Client.chat/3` (behaviour OpenAI-protocol), providers + fallback configurados.
- `Ravanshenasi.Repo.transact_tenant/2`, `with_auth_bypass/1`; `Ravanshenasi.RLS.enable_tenant_rls/1`.
- `Scope` (`clinical_access?/1`, `admin?/1`); `Patients.get_patient!/2`, `list_patient_frameworks/2`; `Records.list_records/2` (prontuários do paciente).
- **Padrão de segurança (Fatias 1–2):** RLS isola só por tenant; o scope isola entre profissionais. **Toda função que recebe um struct (`patient`/`analysis`/`suggestion`) — write OU read/list — escopa a query por `tenant_id`+`user_id`** (usa só o `id` do struct; nas escritas, recarrega o registro antes de operar). Nunca confia no struct do caller. (A lição da Fatia 1 veio justamente de um *list* vazando por struct alheio.) Integridade entre tabelas via **FK composta** `(…, tenant_id, user_id)`.

---

## 2. Decisões de arquitetura (aprovadas)

| # | Decisão | Escolha | Justificativa |
|---|---|---|---|
| F3-D1 | Trigger | **Só manual** ("Analisar paciente") | Controle/custo; auto-após-prontuário fica pra depois |
| F3-D2 | Persistência | `analyses` **+** `suggestions` (tabela separada) | Salvar/descartar **por card** |
| F3-D3 | Reuso de IA | Extrair `AI.chat/1` (fallback) + `AI.generate_suggestions/1` + `AI.Prompts.suggestions_messages/1` + `AI.Suggestions.parse/1` | Generaliza a Fatia 2 sem duplicar |
| F3-D4 | Saída JSON | LLM responde JSON; parse tolerante; malformado → retry Oban | LLM não-determinístico |
| F3-D5 | Async/real-time | Oban (`max_attempts: 3`) + PubSub | Mesmo padrão da Fatia 2 |
| F3-D6 | Isolamento | RLS `tenant_id` + scope `user_id` + FK composta; recarga por id | Padrão consolidado |
| F3-D7 | UI | Botão + cards no `PatientLive.Show` (sem rota nova) | Menor superfície |

---

## 3. Generalização do subsistema de IA (refactor na Fatia 2)

Mudança pequena em `lib/ravanshenasi/ai.ex` (comportamento do SOAP idêntico):
- **Extrair `AI.chat(messages) :: {:ok, %{content, provider, model}} | {:error, {:all_providers_failed, list()}}`** — é o atual `try_providers` (com `configured?`/fallback), agora público e reutilizável.
- `generate_soap(input) = chat(Prompts.soap_messages(input))`.
- Novo `generate_suggestions(input)`:
  ```elixir
  with {:ok, %{content: c, model: m, provider: p}} <- chat(Prompts.suggestions_messages(input)),
       {:ok, suggestions} <- AI.Suggestions.parse(c) do
    {:ok, %{suggestions: suggestions, provider: p, model: m}}
  end
  ```
- `AI.Prompts.suggestions_messages/1` — system+user do `AI_DESIGN.md` (Feature 5), pedindo JSON.
- **`AI.Suggestions.parse/1`** — extrai o array JSON do texto do LLM (tolerante a texto antes/depois: regex/`String.slice` do primeiro `[` ao último `]`), `Jason.decode`, valida que é lista de 2–4 mapas com chaves `framework`/`justification`/`techniques`/`watch_out`. Retorna `{:ok, [%{framework, justification, techniques, watch_out}]}` ou `{:error, :invalid_json}`.

---

## 4. Modelo de dados

Ambas: `:binary_id` PK, RLS por `tenant_id`, FK composta, acessadas via `transact_tenant`.

### `analyses` (scope: `tenant_id` + `user_id`)
| Coluna | Tipo | Notas |
|---|---|---|
| `id` | binary_id | PK |
| `tenant_id` | binary_id | FK → tenants, NOT NULL |
| `user_id` | binary_id | FK composta `(user_id, tenant_id) → users(id, tenant_id)`, NOT NULL |
| `patient_id` | binary_id | FK composta **`(patient_id, tenant_id, user_id) → patients(id, tenant_id, user_id)`**, NOT NULL — amarra o paciente ao MESMO dono da análise (o banco recusa análise com paciente de outro profissional) |
| `generation_status` | enum (`pending`,`generating`,`done`,`error`) | default `pending` |
| `model_used` | string | `"provider:model"`, nullable |
| `error_reason` | string | nullable |
| `inserted_at`/`updated_at` | utc_datetime | |

Índices: `(tenant_id, user_id)`, `(tenant_id, patient_id)`, **unique `(id, tenant_id, user_id)`** (alvo da FK composta da suggestion), e o índice parcial de unicidade (ver §6).
> **Pré-requisito (migration aditiva sobre a Fatia 1):** criar `unique_index(:patients, [:id, :tenant_id, :user_id])` — alvo da FK composta `analyses.patient_id`. Patients hoje só tem `(id, tenant_id)`.

### `suggestions` (scope: `tenant_id` + `user_id`)
| Coluna | Tipo | Notas |
|---|---|---|
| `id` | binary_id | PK |
| `tenant_id` | binary_id | FK → tenants, NOT NULL |
| `user_id` | binary_id | NOT NULL (derivado da analysis) |
| `analysis_id` | binary_id | FK composta **`(analysis_id, tenant_id, user_id) → analyses(id, tenant_id, user_id)`**, NOT NULL |
| `framework_name` | string | a linha de pensamento usada (texto, não FK — o LLM gera o nome) |
| `justification` | text | |
| `techniques` | `{:array, :string}` | técnicas sugeridas |
| `watch_out` | text | pontos de atenção |
| `status` | enum (`suggested`,`saved`,`discarded`) | default `suggested` |
| `inserted_at`/`updated_at` | utc_datetime | |

Índice `(tenant_id, analysis_id)`. As suggestions **derivam** `tenant_id`/`user_id` da analysis (não do caller); a FK composta garante no banco que a suggestion não diverge do tenant/dono da sua análise.

---

## 5. Worker — `GenerateSuggestionsWorker` (espelha o do SOAP)

`use Oban.Worker, queue: :ai, max_attempts: 3`. `perform(%Oban.Job{args: %{"analysis_id" => id, "user_id" => uid, "tenant_id" => tid}, attempt: a, max_attempts: max})`:
1. Reconstrói o scope do dono via `with_auth_bypass` + valida `%User{tenant_id: ^tid}`; user/tenant inexistente → `{:discard, :not_found}`.
2. Carrega a analysis por API escopada (`Analyses.get_analysis(scope, id)`); `nil` → `{:discard, :not_found}`.
3. `Analyses.mark_generating(scope, analysis)` + broadcast.
4. Monta input via contexts scoped: paciente (`Patients.get_patient!`), frameworks ativos (`Patients.list_patient_frameworks`), **os 3 prontuários `done` mais recentes** via `Records.recent_done_records(scope, patient, 3)` (filtro/ordenação no banco).
5. `AI.generate_suggestions(input)` — **fora de transação**.
   - `{:ok, %{suggestions, model, provider}}` → `Analyses.complete(scope, analysis, suggestions, "#{provider}:#{model}")` (insere as N suggestions com `status: suggested`, derivando tenant/user da analysis; analysis `done`) + broadcast → `:ok`.
   - `{:error, reason}`: `a < max` → `{:error, reason}` (retry); `a >= max` → `Analyses.fail(scope, analysis, reason)` (`error`+`error_reason`) + broadcast → `:ok`.

---

## 6. Contexts (API)

### `Ravanshenasi.Analyses`
```
analyze_patient(scope, patient)         # 1) clinical_access?; 2) recarrega o paciente escopado
                                        #    (nil → {:error, :unauthorized}); 3) sem frameworks ativos →
                                        #    {:error, :no_active_frameworks} (não cria nada); 4) se já há
                                        #    análise ATIVA (pending|generating) do paciente → {:ok, active}
                                        #    (idempotente, sem 2º job); 5) senão cria analysis(pending) +
                                        #    Oban.insert! (atômico via transact_tenant).
get_analysis(scope, id) / get_analysis!(scope, id)
list_analyses(scope, %{id: patient_id}) # histórico — query escopada por tenant_id+user_id+patient_id
list_suggestions(scope, %{id})          # cards — query escopada por tenant_id+user_id+analysis_id
save_suggestion(scope, %{id})           # status -> :saved      (recarga escopada por id)
discard_suggestion(scope, %{id})        # status -> :discarded  (recarga escopada por id)
# internos (worker, scope reconstruído):
mark_generating/complete/fail(scope, analysis, ...)
subscribe(analysis_id) / broadcast(analysis)   # tópico "analysis:<id>"
job_args(analysis)
```
- `analyze_patient` opera no paciente **recarregado** (não no struct do caller). "1 análise ativa por paciente" é garantido por um **índice parcial** `unique(tenant_id, user_id, patient_id) WHERE generation_status IN ('pending','generating')` (rede contra corrida de cliques) + a checagem da etapa 4. **Corrida:** se duas requisições passam pela etapa 4 ao mesmo tempo, o insert da 2ª viola o índice parcial — o changeset declara `unique_constraint` nessas colunas, então o insert retorna `{:error, changeset}` (não levanta); `analyze_patient` **captura isso, recarrega a análise ativa e retorna `{:ok, active}`** (idempotente). Nunca deixa `Ecto.ConstraintError` subir.
- `list_analyses`/`list_suggestions` recebem o struct mas **só usam o `id`**; a query escopa por `tenant_id`+`user_id` — struct alheio não retorna dado de outro profissional (read também escopa, §1).
- `complete/4` insere as suggestions numa transação escopada, cada uma com `tenant_id`/`user_id` **derivados da analysis**.
- **"Tentar de novo"** (após `error`) = chamar `analyze_patient` de novo: sem análise ativa, cria uma nova (a anterior em `error` fica no histórico). Sem API de retry separada.
- **Adicionar à API de `Records` (Fatia 2):** `Records.recent_done_records(scope, %{id: patient_id}, limit \\ 3)` — query escopada com **join em `sessions`**, filtrando `generation_status == :done`, **`order_by [desc: session.date]`** (data clínica da sessão, NÃO `records.inserted_at` — uma sessão antiga finalizada depois não bagunça o histórico), `limit`. Filtro/ordenação **no banco**.

---

## 7. Autorização

`clinical_access?` + dono (`user_id`) em **tudo** (analyze, get/list, save/discard). Admin de clínica → `{:error, :unauthorized}`. Toda função — **read, list e write** — escopa/recarrega por query escopada (não confia no struct; ver §1). RLS por `tenant_id` é a rede entre tenants.

---

## 8. Erros e edge cases

| Situação | Comportamento |
|---|---|
| `analyze_patient` de paciente alheio/inexistente | recarga escopada → `{:error, :unauthorized}` |
| JSON do LLM malformado / shape inválido | `{:error, :invalid_json}` → retry Oban; esgotado → analysis `error` |
| Todos os providers falham | analysis `error` + `error_reason` |
| `save`/`discard` de sugestão alheia | recarga escopada → `{:error, :unauthorized}` |
| Paciente sem linhas de pensamento ativas | `analyze_patient` → `{:error, :no_active_frameworks}` (não cria análise/job) — sugestão genérica violaria a premissa do Feature 5 (basear-se **só** nas linhas do terapeuta); UI mostra empty state pedindo pra configurar linhas |
| Clicar "Analisar" com análise já em andamento | retorna a análise ativa existente (`{:ok, active}`, idempotente); índice parcial impede 2 ativas |
| Analysis deletada antes do job | `{:discard, :not_found}` |

---

## 9. Real-time (PubSub)
Tópico `"analysis:<id>"`. Worker faz broadcast em `generating`/`done`/`error`. O `PatientLive.Show` assina a análise corrente e atualiza: `pending`/`generating` → "Analisando…"; `done` → renderiza os cards (com botões salvar/descartar por card); `error` → mensagem + "tentar de novo".

---

## 10. UI (no `PatientLive.Show`)
- Botão **"Analisar paciente"** → `Analyses.analyze_patient(scope, patient)`:
  - `{:ok, analysis}` → assina o tópico, mostra "Analisando…".
  - `{:error, :no_active_frameworks}` → **empty state**: "Configure linhas de pensamento para este paciente antes de analisar".
  - `{:error, :unauthorized}` → flash.
- Cards: cada suggestion mostra `framework_name`, `justification`, `techniques`, `watch_out`, com botões **Salvar**/**Descartar** (`save_suggestion`/`discard_suggestion`) e indicação do `status`.
- Análise em `error` → mensagem + botão **"Tentar de novo"** que chama `analyze_patient` de novo (cria nova análise).
- (Opcional, YAGNI) histórico via `list_analyses` — fora do MVP; foco na análise corrente.

---

## 11. Estratégia de testes
`async: false` onde toca `transact_tenant`/bypass. Oban `:manual` (`assert_enqueued`/`perform_job`). Stub de IA com `content` = **JSON** controlado.

- **`AI.Suggestions.parse/1`**: JSON válido (2–4 itens), JSON com texto antes/depois, malformado → `{:error, :invalid_json}`, fora do range (0 ou >4) → erro.
- **`AI.chat/1`** (extraído): fallback continua passando (reusa os testes da Fatia 2; ajustar se a assinatura mudar).
- **`AI.generate_suggestions/1`**: stub com JSON válido → `{:ok, %{suggestions: [...]}}`.
- **`Analyses`**: `analyze_patient` cria `pending` + `assert_enqueued`; isolamento entre profissionais (analysis de A invisível pra B do mesmo tenant); `save`/`discard` muda status; alheio → `:unauthorized`.
- **`GenerateSuggestionsWorker`** (`perform_job`): stub JSON válido → analysis `done` + N suggestions + broadcast; stub inválido em todos attempts → analysis `error`.
- **LiveView**: "Analisar paciente" → "Analisando"; broadcast `done` → cards aparecem; salvar/descartar um card muda o estado. IDs estáveis (`#analyze-patient-button`, `#suggestion-<id>`, etc.) + `element`/`has_element?`.

---

## 12. Estrutura de arquivos
```
lib/ravanshenasi/
  analyses.ex
  analyses/analysis.ex
  analyses/suggestion.ex
  analyses/generate_suggestions_worker.ex     # Oban.Worker
  ai.ex                                        # +chat/1, +generate_suggestions/1
  ai/prompts.ex                                # +suggestions_messages/1
  ai/suggestions.ex                            # parse/1 (JSON → structs validados)
  records.ex                                   # +recent_done_records/3 (estende a Fatia 2)
lib/ravanshenasi_web/live/patient_live/show.ex # +botão Analisar +cards +save/discard +PubSub +empty/error states
priv/repo/migrations/
  *_add_patient_user_unique_index.exs          # unique patients (id, tenant_id, user_id) — alvo da FK composta
  *_create_analyses.exs                        # FK composta (patient/user) + RLS + unique (id,tenant_id,user_id) + índice parcial de "1 ativa"
  *_create_suggestions.exs                     # FK composta + RLS
```

---

## 13. Fora de escopo (fatias futuras)
- Trigger automático após prontuário (decidido: só manual).
- Áudio/Whisper (Fatia 4), Dashboard (Fatia 5).
- FK real entre `framework_name` e `thinking_frameworks` (o LLM gera o nome livremente; guardamos string).
- Edição manual das sugestões / regeneração parcial (há "tentar de novo" que recria a análise inteira).
- Histórico rico de análises (lista simples basta no MVP).

---

## 14. Definition of Done
- [ ] `AI.chat/1` extraído (SOAP idêntico); `generate_suggestions/1` + `Prompts.suggestions_messages/1` + `AI.Suggestions.parse/1` (parse tolerante + validação 2–4 itens); `Records.recent_done_records/3` (filtro/ordenação no banco).
- [ ] Migrations: unique `patients (id, tenant_id, user_id)`; `analyses` + `suggestions` com FK composta `(…, tenant_id, user_id)` — incl. `analyses.patient_id` amarrando **paciente↔dono** — + RLS; unique `(id, tenant_id, user_id)` em analyses; **índice parcial** `(tenant_id, user_id, patient_id) WHERE generation_status ∈ (pending,generating)`.
- [ ] `Analyses`: `analyze_patient` atômico (analysis `pending` + `assert_enqueued`); **bloqueia sem frameworks** (`:no_active_frameworks`); **idempotente** (1 análise ativa por paciente); `complete` insere suggestions derivando tenant/user; `save`/`discard` por card. **Reads E writes** escopam/recarregam por id (`list_analyses`/`list_suggestions` não vazam struct alheio).
- [ ] `GenerateSuggestionsWorker`: scope reconstruído (valida user↔tenant), IA fora de transação, `done`/`error` (último attempt), `discard` se não achar; JSON malformado → retry.
- [ ] Autorização: admin de clínica sem acesso; isolamento entre profissionais testado (incl. `list`).
- [ ] PubSub: `PatientLive.Show` "Analisando" → cards / erro (+tentar de novo) / empty state sem frameworks; salvar/descartar por card; IDs estáveis nos testes.
- [ ] `mix precommit` verde; testes não batem na API real (stub).
