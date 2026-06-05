# Fatia 3 — Sugestão de Abordagens Terapêuticas (IA) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **WORKFLOW CONSTRAINT (deste projeto, não-negociável):** Trabalhar **direto na `main`**, **SEM branches**. **NÃO commitar** — o usuário faz os commits. Por isso este plano **não tem passos de commit**: cada task termina com testes verdes e deixa a working tree pronta. NÃO rodar `git add`/`git commit`/`git push`. NÃO adicionar trailer `Co-Authored-By`/`Generated with` em lugar nenhum.

**Goal:** A partir do perfil do paciente + linhas de pensamento ativas + prontuários recentes, um LLM sugere 2–4 abordagens terapêuticas em cards que o profissional salva/descarta, no `PatientLive.Show`.

**Architecture:** Reusa o subsistema de IA da Fatia 2 (providers OpenAI-protocol + fallback + Oban + PubSub). Generaliza `AI` extraindo `chat/1`; acrescenta `generate_suggestions/1`, `Prompts.suggestions_messages/1` e o parser tolerante `AI.Suggestions.parse/1` (JSON → structs validados, 2–4 itens). Duas tabelas novas (`analyses`, `suggestions`) com RLS por tenant + scope por `user_id` + FKs compostas. Um `GenerateSuggestionsWorker` (espelha o do SOAP) roda a IA fora de transação e persiste via context escopado. Isolamento entre profissionais: **toda** função (read e write) recarrega/escopa por query (`tenant_id`+`user_id`), nunca confia no struct do caller.

**Tech Stack:** Elixir 1.19 / Phoenix 1.8.7 / LiveView 1.1 / Ecto / TimescaleDB pg17 / Oban ~2.23 / `req` / Jason.

**Invariante crítico (descoberto no código):** `Repo.transact_tenant/2` faz `SET LOCAL app.current_tenant_id = ''` no caminho de sucesso (`lib/ravanshenasi/repo.ex:25`). Portanto **NÃO aninhar `transact_tenant` dentro de `transact_tenant`** — o reset da transação interna deixaria a externa fail-closed (GUC vazio = RLS nega tudo). Dentro de um `transact_tenant`, recarregue/consulte **inline** com query escopada (como `Sessions.insert_session` faz), nunca chamando `Patients.get_patient`/`Records.*`/etc. (que abrem a própria transação). Fora de transação (ex.: no worker, sequencialmente), pode chamar os contexts à vontade.

---

## File Structure

| Arquivo | Responsabilidade |
|---|---|
| `lib/ravanshenasi/ai.ex` | **Modificar:** extrair `chat/1` público (era `try_providers`); `generate_soap/1 = chat(soap_messages)`; novo `generate_suggestions/1`. |
| `lib/ravanshenasi/ai/prompts.ex` | **Modificar:** novo `suggestions_messages/1` (system+user do AI_DESIGN Feature 5, pedindo JSON). |
| `lib/ravanshenasi/ai/suggestions.ex` | **Criar:** `parse/1` — extrai array JSON tolerante, valida 2–4 itens com as 4 chaves. |
| `lib/ravanshenasi/analyses/analysis.ex` | **Criar:** schema `analyses` + changesets (insert com `unique_constraint`, status). |
| `lib/ravanshenasi/analyses/suggestion.ex` | **Criar:** schema `suggestions` + changesets (insert, status). |
| `lib/ravanshenasi/analyses.ex` | **Criar:** context — `analyze_patient`, `get_analysis(!)`, `list_analyses`, `list_suggestions`, `save_suggestion`, `discard_suggestion`, internos `mark_generating`/`complete`/`fail`, `subscribe`/`broadcast`, `job_args`. |
| `lib/ravanshenasi/analyses/generate_suggestions_worker.ex` | **Criar:** Oban worker (espelha `GenerateSoapWorker`). |
| `lib/ravanshenasi/records.ex` | **Modificar:** `recent_done_records/3` (join sessions, filtro `done`, order `session.date desc`, no banco). |
| `lib/ravanshenasi_web/live/patient_live/show.ex` | **Modificar:** botão "Analisar", cards, save/discard, PubSub, empty/error states. |
| `priv/repo/migrations/*_add_patient_user_unique_index.exs` | **Criar:** `unique_index(:patients, [:id, :tenant_id, :user_id])` — alvo da FK composta de `analyses`. |
| `priv/repo/migrations/*_create_analyses.exs` | **Criar:** tabela + FKs compostas + RLS + unique `(id,tenant_id,user_id)` + índice parcial "1 ativa". |
| `priv/repo/migrations/*_create_suggestions.exs` | **Criar:** tabela + FK composta + RLS. |

**Ordem de execução:** Tasks 1–4 (IA, sem dependência de DB) → 5–7 (migrations) → 8–9 (schemas) → 10 (Records) → 11–13 (Analyses context) → 14 (worker) → 15 (LiveView). Cada task é TDD: teste que falha → roda e vê falhar → implementa mínimo → roda e vê passar.

---

## Task 1: Extrair `AI.chat/1` (generalizar o facade)

**Files:**
- Modify: `lib/ravanshenasi/ai.ex`
- Test: `test/ravanshenasi/ai_test.exs` (já existe; acrescentar teste de `chat/1`)

Comportamento do SOAP fica **idêntico**: `chat/1` é o atual `try_providers` exposto, e `generate_soap/1` passa a ser `chat(Prompts.soap_messages(input))`.

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar ao final de `test/ravanshenasi/ai_test.exs` (dentro do `describe` ou no nível do módulo, seguindo o estilo do arquivo — usa `Application.put_env` com `on_exit` de restore):

```elixir
  test "chat/1 tenta providers na ordem e devolve o primeiro ok" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad, :good],
      providers: %{
        bad: %{client: Ravanshenasi.AI.Client.Stub, behavior: :error, model: "bad"},
        good: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: "OI", model: "good"}
      }
    )

    assert {:ok, %{content: "OI", provider: :good, model: "good"}} =
             Ravanshenasi.AI.chat([%{role: "user", content: "x"}])
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/ai_test.exs -v`
Expected: FAIL — `function Ravanshenasi.AI.chat/1 is undefined or private`.

- [ ] **Step 3: Implementar (refactor mínimo)**

Em `lib/ravanshenasi/ai.ex`, substituir o corpo de `generate_soap/1` e expor `chat/1`. O bloco `try_providers`/`try_one`/`configured?`/`present?` **fica como está** (já privado). Resultado:

```elixir
defmodule Ravanshenasi.AI do
  @moduledoc "Domain facade: builds chat messages and tries providers in order (fallback)."

  alias Ravanshenasi.AI.Prompts

  @type chat_ok :: %{content: String.t(), provider: atom(), model: String.t()}

  @spec chat([map()]) :: {:ok, chat_ok()} | {:error, {:all_providers_failed, list()}}
  def chat(messages) do
    cfg = Application.fetch_env!(:ravanshenasi, __MODULE__)
    try_providers(cfg[:order], cfg[:providers], messages, [])
  end

  @spec generate_soap(map()) :: {:ok, chat_ok()} | {:error, {:all_providers_failed, list()}}
  def generate_soap(input), do: chat(Prompts.soap_messages(input))

  # ... try_providers/4, try_one/6, configured?/1, present?/1 — INALTERADOS ...
end
```

- [ ] **Step 4: Rodar e ver passar (incl. os testes existentes do SOAP)**

Run: `mix test test/ravanshenasi/ai_test.exs -v`
Expected: PASS — o novo teste + os testes de `generate_soap` antigos (fallback/all-failed) continuam verdes.

---

## Task 2: `AI.Prompts.suggestions_messages/1`

**Files:**
- Modify: `lib/ravanshenasi/ai/prompts.ex`
- Test: `test/ravanshenasi/ai/prompts_test.exs` (já existe; acrescentar)

System+user do AI_DESIGN Feature 5: baseia-se **só** nas abordagens do terapeuta, pede JSON de 2–4 itens. Input: `%{patient, frameworks, recent_records}`.

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/ai/prompts_test.exs`:

```elixir
  test "suggestions_messages monta system+user com frameworks e pede JSON" do
    input = %{
      patient: %{name: "Ana", birth_date: ~D[1990-01-01], chief_complaint: "ansiedade", relevant_history: "—"},
      frameworks: [%{name: "TCC", description: "cognitivo-comportamental"}],
      recent_records: [%{content: "S:..\nO:..\nA:..\nP:..", inserted_at: ~U[2026-06-01 10:00:00Z]}]
    }

    assert [%{role: "system", content: sys}, %{role: "user", content: user}] =
             Ravanshenasi.AI.Prompts.suggestions_messages(input)

    assert sys =~ "abordagens terapêuticas listadas"
    assert user =~ "TCC"
    assert user =~ "ansiedade"
    assert user =~ "JSON"
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/ai/prompts_test.exs -v`
Expected: FAIL — `function Ravanshenasi.AI.Prompts.suggestions_messages/1 is undefined`.

- [ ] **Step 3: Implementar**

Acrescentar a `lib/ravanshenasi/ai/prompts.ex` (reusa `age/1` que já existe no módulo):

```elixir
  @suggestions_system """
  Você é um supervisor clínico em psicologia com amplo conhecimento em múltiplas \
  abordagens terapêuticas. Sua função é analisar o perfil de um paciente e sugerir \
  vertentes de abordagem para o próximo atendimento. Baseie suas sugestões \
  exclusivamente nas abordagens terapêuticas listadas pelo terapeuta. Seja específico, \
  clínico e justifique cada sugestão com base no perfil do paciente.
  """

  @spec suggestions_messages(map()) :: [map()]
  def suggestions_messages(%{patient: p, frameworks: fws, recent_records: recs}) do
    [
      %{role: "system", content: String.trim(@suggestions_system)},
      %{role: "user", content: suggestions_user(p, fws, recs)}
    ]
  end

  defp suggestions_user(p, fws, recs) do
    """
    Abordagens terapêuticas que o terapeuta utiliza:
    #{frameworks_block(fws)}

    Perfil do paciente:
    - Nome: #{p.name} | Idade: #{age(p.birth_date)}
    - Queixa principal: #{p.chief_complaint}
    - Histórico: #{p.relevant_history}

    Histórico de sessões e prontuários recentes:
    #{records_block(recs)}

    Gere entre 2 e 4 sugestões de abordagem para o próximo atendimento.
    Responda APENAS em JSON, um array no formato:
    [
      {"framework": "nome da abordagem", "justification": "por quê para este paciente",
       "techniques": ["técnica 1", "técnica 2"], "watch_out": "pontos de atenção/riscos"}
    ]
    """
  end

  defp records_block([]), do: "- (nenhum prontuário recente)"
  defp records_block(recs), do: Enum.map_join(recs, "\n\n", & &1.content)
```

> `frameworks_block/1` já existe no módulo (lida com `[]` e com a lista). `age/1` idem.

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/ai/prompts_test.exs -v`
Expected: PASS.

---

## Task 3: `AI.Suggestions.parse/1` (parser tolerante)

**Files:**
- Create: `lib/ravanshenasi/ai/suggestions.ex`
- Test: `test/ravanshenasi/ai/suggestions_test.exs`

Extrai o array do primeiro `[` ao último `]` (tolerante a texto antes/depois), `Jason.decode`, valida **lista de 2–4 mapas** com as 4 chaves (`techniques` precisa ser lista). Usa `binary_part` (bytes) — casa com `:binary.match` mesmo em UTF-8.

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ravanshenasi/ai/suggestions_test.exs`:

```elixir
defmodule Ravanshenasi.AI.SuggestionsTest do
  use ExUnit.Case, async: true
  alias Ravanshenasi.AI.Suggestions

  @valid ~s([{"framework":"TCC","justification":"j1","techniques":["t1","t2"],"watch_out":"w1"},
             {"framework":"ACT","justification":"j2","techniques":["t3"],"watch_out":"w2"}])

  test "JSON válido (2 itens) → structs normalizados" do
    assert {:ok, [a, b]} = Suggestions.parse(@valid)
    assert a == %{framework: "TCC", justification: "j1", techniques: ["t1", "t2"], watch_out: "w1"}
    assert b.framework == "ACT"
  end

  test "tolera texto antes e depois do array" do
    blob = "Claro! Aqui estão:\n" <> @valid <> "\nEspero ter ajudado."
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
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/ai/suggestions_test.exs -v`
Expected: FAIL — `Ravanshenasi.AI.Suggestions.parse/1 is undefined` (módulo não existe).

- [ ] **Step 3: Implementar**

Criar `lib/ravanshenasi/ai/suggestions.ex`:

```elixir
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
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/ai/suggestions_test.exs -v`
Expected: PASS (5 testes).

---

## Task 4: `AI.generate_suggestions/1`

**Files:**
- Modify: `lib/ravanshenasi/ai.ex`
- Test: `test/ravanshenasi/ai_test.exs`

Encadeia `chat(suggestions_messages)` + `Suggestions.parse`.

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/ai_test.exs`:

```elixir
  test "generate_suggestions/1 com JSON válido do provider → {:ok, %{suggestions}}" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    json =
      ~s([{"framework":"TCC","justification":"j","techniques":["t"],"watch_out":"w"},
          {"framework":"ACT","justification":"j2","techniques":["t2"],"watch_out":"w2"}])

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:good],
      providers: %{good: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: json, model: "good"}}
    )

    input = %{
      patient: %{name: "Ana", birth_date: nil, chief_complaint: "x", relevant_history: "y"},
      frameworks: [%{name: "TCC", description: "d"}],
      recent_records: []
    }

    assert {:ok, %{suggestions: [s1, _s2], provider: :good, model: "good"}} =
             Ravanshenasi.AI.generate_suggestions(input)

    assert s1.framework == "TCC"
  end

  test "generate_suggestions/1 com JSON inválido → {:error, :invalid_json}" do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:good],
      providers: %{good: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: "sem json", model: "good"}}
    )

    input = %{patient: %{name: "Ana", birth_date: nil, chief_complaint: "x", relevant_history: "y"},
              frameworks: [], recent_records: []}

    assert {:error, :invalid_json} = Ravanshenasi.AI.generate_suggestions(input)
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/ai_test.exs -v`
Expected: FAIL — `function Ravanshenasi.AI.generate_suggestions/1 is undefined`.

- [ ] **Step 3: Implementar**

Em `lib/ravanshenasi/ai.ex`, atualizar o alias e acrescentar a função:

```elixir
  alias Ravanshenasi.AI.{Prompts, Suggestions}
```

```elixir
  @spec generate_suggestions(map()) ::
          {:ok, %{suggestions: [map()], provider: atom(), model: String.t()}}
          | {:error, {:all_providers_failed, list()} | :invalid_json}
  def generate_suggestions(input) do
    with {:ok, %{content: content, provider: provider, model: model}} <-
           chat(Prompts.suggestions_messages(input)),
         {:ok, suggestions} <- Suggestions.parse(content) do
      {:ok, %{suggestions: suggestions, provider: provider, model: model}}
    end
  end
```

> `with` propaga `{:error, {:all_providers_failed, _}}` (do `chat`) e `{:error, :invalid_json}` (do parse) sem cláusula `else`.

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/ai_test.exs -v`
Expected: PASS (todos, incl. SOAP e os 2 novos).

---

## Task 5: Migration — unique `patients (id, tenant_id, user_id)`

**Files:**
- Create: `priv/repo/migrations/*_add_patient_user_unique_index.exs`

Alvo da FK composta de 3 colunas de `analyses.patient_id`. Hoje patients só tem unique `(id, tenant_id)`.

- [ ] **Step 1: Gerar a migration**

Run: `mix ecto.gen.migration add_patient_user_unique_index`
Isso cria `priv/repo/migrations/<timestamp>_add_patient_user_unique_index.exs`.

- [ ] **Step 2: Escrever o conteúdo**

Substituir o corpo do arquivo gerado por:

```elixir
defmodule Ravanshenasi.Repo.Migrations.AddPatientUserUniqueIndex do
  use Ecto.Migration

  def change do
    # Composite-FK target for analyses.patient_id (id, tenant_id, user_id) — ties an
    # analysis's patient to the SAME owner. Patients today only have (id, tenant_id).
    create unique_index(:patients, [:id, :tenant_id, :user_id])
  end
end
```

- [ ] **Step 3: Migrar**

Run: `mix ecto.migrate`
Expected: cria o índice sem erro (`create index patients_id_tenant_id_user_id_index`).

- [ ] **Step 4: Verificar**

Run: `mix ecto.migrations`
Expected: a migration aparece como `up`.

---

## Task 6: Migration — `create_analyses`

**Files:**
- Create: `priv/repo/migrations/*_create_analyses.exs`

Tabela + FK composta user→users (via `with:`) + FK composta de 3 colunas patient (raw SQL, como `records` faz) + RLS + unique `(id,tenant_id,user_id)` + índice parcial "1 ativa por paciente".

- [ ] **Step 1: Gerar**

Run: `mix ecto.gen.migration create_analyses`

- [ ] **Step 2: Escrever o conteúdo**

```elixir
defmodule Ravanshenasi.Repo.Migrations.CreateAnalyses do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:analyses, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      # Composite FK: owner must be a user OF THE SAME TENANT.
      add :user_id,
          references(:users, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :restrict),
          null: false

      # 3-column composite FK added via raw SQL below (references/with: only does 2 cols).
      add :patient_id, :binary_id, null: false

      add :generation_status, :string, null: false, default: "pending"
      add :model_used, :string
      add :error_reason, :string

      timestamps(type: :utc_datetime)
    end

    # Ties patient to the SAME tenant AND owner: the DB rejects an analysis whose
    # patient belongs to another practitioner. Target: patients (id, tenant_id, user_id).
    execute(
      "ALTER TABLE analyses ADD CONSTRAINT analyses_patient_owner_fkey FOREIGN KEY (patient_id, tenant_id, user_id) REFERENCES patients (id, tenant_id, user_id) ON DELETE CASCADE",
      "ALTER TABLE analyses DROP CONSTRAINT analyses_patient_owner_fkey"
    )

    create index(:analyses, [:tenant_id, :user_id])
    create index(:analyses, [:tenant_id, :patient_id])
    # Composite-FK target for suggestions.analysis_id.
    create unique_index(:analyses, [:id, :tenant_id, :user_id])

    # Partial unique index: at most ONE active (pending|generating) analysis per patient.
    # Net against double-click races; the changeset declares this constraint name.
    create unique_index(:analyses, [:tenant_id, :user_id, :patient_id],
             where: "generation_status IN ('pending','generating')",
             name: :analyses_one_active_per_patient
           )

    enable_tenant_rls("analyses")
  end
end
```

- [ ] **Step 3: Migrar**

Run: `mix ecto.migrate`
Expected: tabela `analyses` criada, FK composta e índice parcial sem erro.

- [ ] **Step 4: Verificar a constraint**

Run: `psql $DATABASE_URL -c "\d analyses"` (ou pular se não houver psql — `mix ecto.migrations` mostrando `up` basta)
Expected: ver `analyses_patient_owner_fkey` e `analyses_one_active_per_patient`.

---

## Task 7: Migration — `create_suggestions`

**Files:**
- Create: `priv/repo/migrations/*_create_suggestions.exs`

FK composta de 3 colunas analysis→analyses (raw SQL). `user_id` é `:binary_id` puro (coberto pela FK composta da analysis — espelha `records.user_id`).

- [ ] **Step 1: Gerar**

Run: `mix ecto.gen.migration create_suggestions`

- [ ] **Step 2: Escrever o conteúdo**

```elixir
defmodule Ravanshenasi.Repo.Migrations.CreateSuggestions do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:suggestions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      # Derived from the analysis; consistency enforced by the composite FK below.
      add :user_id, :binary_id, null: false
      add :analysis_id, :binary_id, null: false

      add :framework_name, :string, null: false
      add :justification, :text
      add :techniques, {:array, :string}, null: false, default: []
      add :watch_out, :text
      add :status, :string, null: false, default: "suggested"

      timestamps(type: :utc_datetime)
    end

    # Suggestion must not diverge from its analysis's tenant/owner.
    execute(
      "ALTER TABLE suggestions ADD CONSTRAINT suggestions_analysis_owner_fkey FOREIGN KEY (analysis_id, tenant_id, user_id) REFERENCES analyses (id, tenant_id, user_id) ON DELETE CASCADE",
      "ALTER TABLE suggestions DROP CONSTRAINT suggestions_analysis_owner_fkey"
    )

    create index(:suggestions, [:tenant_id, :analysis_id])
    create index(:suggestions, [:tenant_id, :user_id])

    enable_tenant_rls("suggestions")
  end
end
```

- [ ] **Step 3: Migrar**

Run: `mix ecto.migrate`
Expected: tabela `suggestions` criada sem erro.

- [ ] **Step 4: Verificar**

Run: `mix ecto.migrations`
Expected: as 3 migrations (5,6,7) como `up`.

---

## Task 8: Schema `Analysis`

**Files:**
- Create: `lib/ravanshenasi/analyses/analysis.ex`
- Test: `test/ravanshenasi/analyses/analysis_test.exs`

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ravanshenasi/analyses/analysis_test.exs`:

```elixir
defmodule Ravanshenasi.Analyses.AnalysisTest do
  use ExUnit.Case, async: true
  alias Ravanshenasi.Analyses.Analysis

  test "insert_changeset exige tenant/user/patient e nasce pending" do
    cs = Analysis.insert_changeset(%{tenant_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate(), patient_id: Ecto.UUID.generate()})
    assert cs.valid?
    assert Ecto.Changeset.apply_changes(cs).generation_status == :pending
  end

  test "insert_changeset inválido sem patient_id" do
    cs = Analysis.insert_changeset(%{tenant_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate()})
    refute cs.valid?
  end

  test "status_changeset altera generation_status/model/erro" do
    cs = Analysis.status_changeset(%Analysis{}, %{generation_status: :done, model_used: "stub:m"})
    assert Ecto.Changeset.apply_changes(cs).generation_status == :done
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/analyses/analysis_test.exs -v`
Expected: FAIL — módulo `Ravanshenasi.Analyses.Analysis` não existe.

- [ ] **Step 3: Implementar**

Criar `lib/ravanshenasi/analyses/analysis.ex`:

```elixir
defmodule Ravanshenasi.Analyses.Analysis do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "analyses" do
    field :generation_status, Ecto.Enum,
      values: [:pending, :generating, :done, :error],
      default: :pending

    field :model_used, :string
    field :error_reason, :string

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User
    belongs_to :patient, Ravanshenasi.Patients.Patient
    has_many :suggestions, Ravanshenasi.Analyses.Suggestion

    timestamps(type: :utc_datetime)
  end

  @doc """
  Insert changeset for a new (pending) analysis. Declares the partial unique index
  so a concurrent double-click returns {:error, changeset} instead of raising
  Ecto.ConstraintError — the context catches it and returns the active analysis.
  """
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:tenant_id, :user_id, :patient_id])
    |> validate_required([:tenant_id, :user_id, :patient_id])
    |> unique_constraint([:tenant_id, :user_id, :patient_id],
      name: :analyses_one_active_per_patient
    )
  end

  @doc "Status transitions (generating/done/error)."
  def status_changeset(analysis, attrs) do
    cast(analysis, attrs, [:generation_status, :model_used, :error_reason])
  end
end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/analyses/analysis_test.exs -v`
Expected: PASS (3 testes).

---

## Task 9: Schema `Suggestion`

**Files:**
- Create: `lib/ravanshenasi/analyses/suggestion.ex`
- Test: `test/ravanshenasi/analyses/suggestion_test.exs`

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ravanshenasi/analyses/suggestion_test.exs`:

```elixir
defmodule Ravanshenasi.Analyses.SuggestionTest do
  use ExUnit.Case, async: true
  alias Ravanshenasi.Analyses.Suggestion

  test "insert_changeset monta os campos e nasce suggested" do
    cs =
      Suggestion.insert_changeset(%{
        tenant_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        analysis_id: Ecto.UUID.generate(),
        framework_name: "TCC",
        justification: "j",
        techniques: ["t1", "t2"],
        watch_out: "w"
      })

    assert cs.valid?
    applied = Ecto.Changeset.apply_changes(cs)
    assert applied.status == :suggested
    assert applied.techniques == ["t1", "t2"]
  end

  test "status_changeset muda status" do
    cs = Suggestion.status_changeset(%Suggestion{}, %{status: :saved})
    assert Ecto.Changeset.apply_changes(cs).status == :saved
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/analyses/suggestion_test.exs -v`
Expected: FAIL — módulo não existe.

- [ ] **Step 3: Implementar**

Criar `lib/ravanshenasi/analyses/suggestion.ex`:

```elixir
defmodule Ravanshenasi.Analyses.Suggestion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "suggestions" do
    field :framework_name, :string
    field :justification, :string
    field :techniques, {:array, :string}, default: []
    field :watch_out, :string
    field :status, Ecto.Enum, values: [:suggested, :saved, :discarded], default: :suggested

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User
    belongs_to :analysis, Ravanshenasi.Analyses.Analysis

    timestamps(type: :utc_datetime)
  end

  @doc "Insert changeset. tenant_id/user_id are DERIVED from the analysis, never the caller."
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :analysis_id,
      :framework_name,
      :justification,
      :techniques,
      :watch_out,
      :status
    ])
    |> validate_required([:tenant_id, :user_id, :analysis_id, :framework_name])
  end

  @doc "Save/discard a card."
  def status_changeset(suggestion, attrs), do: cast(suggestion, attrs, [:status])
end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/analyses/suggestion_test.exs -v`
Expected: PASS (2 testes).

---

## Task 10: `Records.recent_done_records/3`

**Files:**
- Modify: `lib/ravanshenasi/records.ex`
- Test: `test/ravanshenasi/records_test.exs` (já existe; acrescentar)

Join em `sessions`, filtra `generation_status == :done`, ordena por **`session.date desc`** (data clínica, NÃO `records.inserted_at`), limita. Tudo no banco.

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/records_test.exs` (o setup já cria `scope`, `patient`, `session`, `record` pending — ver topo do arquivo; aqui criamos dois records `done` com datas de sessão distintas):

```elixir
  test "recent_done_records traz só :done, ordenado por session.date desc, limitado", %{scope: s} do
    {:ok, p} = Ravanshenasi.Patients.create_patient(s, %{name: "Rec"})

    {:ok, old_sess} = Ravanshenasi.Sessions.create_session(s, p, %{notes: "n", date: ~U[2026-01-01 10:00:00Z]})
    {:ok, new_sess} = Ravanshenasi.Sessions.create_session(s, p, %{notes: "n", date: ~U[2026-05-01 10:00:00Z]})

    {:ok, r_old} = insert_record(s, old_sess, p)
    {:ok, r_new} = insert_record(s, new_sess, p)
    {:ok, _} = Records.complete(s, r_old, "OLD", "m")
    {:ok, _} = Records.complete(s, r_new, "NEW", "m")

    # um record pending NÃO entra
    {:ok, pend_sess} = Ravanshenasi.Sessions.create_session(s, p, %{notes: "n", date: ~U[2026-06-01 10:00:00Z]})
    {:ok, _pending} = insert_record(s, pend_sess, p)

    result = Records.recent_done_records(s, %{id: p.id}, 3)
    assert Enum.map(result, & &1.content) == ["NEW", "OLD"]
  end
```

> `insert_record/3` é o helper privado já existente no arquivo de teste (insere via `transact_tenant`).

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/records_test.exs -v`
Expected: FAIL — `function Ravanshenasi.Records.recent_done_records/3 is undefined`.

- [ ] **Step 3: Implementar**

Em `lib/ravanshenasi/records.ex`, acrescentar o alias e a função (o módulo já tem `import Ecto.Query`, `scoped/2`, `transact_tenant`):

```elixir
  alias Ravanshenasi.Sessions.Session
```

```elixir
  @doc """
  Últimos `limit` prontuários :done do paciente (do dono), ordenados pela DATA CLÍNICA
  da sessão (desc) — não por inserted_at, pra uma sessão antiga finalizada depois não
  furar a ordem. Filtro/ordenação no banco.
  """
  def recent_done_records(%Scope{} = scope, %{id: patient_id}, limit \\ 3) do
    transact_tenant(scope, fn ->
      Record
      |> scoped(scope)
      |> join(:inner, [r], se in Session, on: se.id == r.session_id)
      |> where([r, se], r.patient_id == ^patient_id and r.generation_status == :done)
      |> order_by([r, se], desc: se.date)
      |> limit(^limit)
      |> select([r, se], r)
      |> Repo.all()
    end)
  end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/records_test.exs -v`
Expected: PASS (incl. os testes antigos de records).

---

## Task 11: `Analyses` — `analyze_patient` + `get_analysis(!)` + helpers

**Files:**
- Create: `lib/ravanshenasi/analyses.ex`
- Test: `test/ravanshenasi/analyses_test.exs`

`analyze_patient`: `clinical_access?` → recarrega patient **inline** escopado (nil → `:unauthorized`) → sem framework ativo → `:no_active_frameworks` → análise ativa existente → `{:ok, active}` (idempotente) → senão insere `pending` + `Oban.insert!` (race no índice parcial vira `{:ok, active}`). **Tudo num único `transact_tenant`** (nunca aninhar — invariante do topo).

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ravanshenasi/analyses_test.exs`:

```elixir
defmodule Ravanshenasi.AnalysesTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Analyses, Frameworks, Patients}
  alias Ravanshenasi.Analyses.GenerateSuggestionsWorker

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    framework = Frameworks.list_frameworks(scope) |> hd()
    :ok = Patients.activate_framework(scope, patient, framework)
    %{scope: scope, patient: patient}
  end

  test "analyze_patient cria pending + enfileira job", %{scope: s, patient: p} do
    assert {:ok, analysis} = Analyses.analyze_patient(s, p)
    assert analysis.generation_status == :pending
    assert_enqueued(worker: GenerateSuggestionsWorker, args: %{analysis_id: analysis.id})
  end

  test "analyze_patient sem frameworks ativos → :no_active_frameworks (sem job)" do
    s = user_scope_fixture()
    {:ok, p} = Patients.create_patient(s, %{name: "Sem Linha"})
    assert {:error, :no_active_frameworks} = Analyses.analyze_patient(s, p)
    assert [] = all_enqueued(worker: GenerateSuggestionsWorker)
  end

  test "analyze_patient é idempotente: 2ª chamada devolve a ativa, sem 2º job", %{scope: s, patient: p} do
    assert {:ok, a1} = Analyses.analyze_patient(s, p)
    assert {:ok, a2} = Analyses.analyze_patient(s, p)
    assert a1.id == a2.id
    assert [_one] = all_enqueued(worker: GenerateSuggestionsWorker)
  end

  test "analyze_patient de paciente de OUTRO profissional → :unauthorized" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})

    assert {:error, :unauthorized} = Analyses.analyze_patient(b, pa)
  end

  test "admin de clínica não tem acesso clínico → :unauthorized", %{patient: p} do
    admin = clinic_admin_scope_fixture()
    assert {:error, :unauthorized} = Analyses.analyze_patient(admin, p)
  end

  test "get_analysis escopa por dono", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    assert Analyses.get_analysis(s, a.id).id == a.id

    other = user_scope_fixture()
    assert Analyses.get_analysis(other, a.id) == nil
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/analyses_test.exs -v`
Expected: FAIL — módulo `Ravanshenasi.Analyses` não existe.

- [ ] **Step 3: Implementar**

Criar `lib/ravanshenasi/analyses.ex` (esta task entrega `analyze_patient`, `get_analysis(!)`, `job_args`, `subscribe`, `broadcast` e os helpers privados; as Tasks 12–13 acrescentam o resto no mesmo módulo):

```elixir
defmodule Ravanshenasi.Analyses do
  @moduledoc "Therapy-approach suggestions, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Analyses.{Analysis, GenerateSuggestionsWorker, Suggestion}
  alias Ravanshenasi.Patients.{Patient, PatientFramework}
  alias Ravanshenasi.Repo

  @pubsub Ravanshenasi.PubSub
  @active_statuses [:pending, :generating]

  @doc """
  Dispara a análise de um paciente. NÃO confia no struct: recarrega o paciente por
  query escopada. Idempotente (1 análise ativa por paciente). Bloqueia sem frameworks
  ativos. Tudo num único transact_tenant (não aninhar — transact_tenant reseta o GUC).
  """
  def analyze_patient(%Scope{} = scope, %{id: patient_id}) do
    if Scope.clinical_access?(scope),
      do: do_analyze(scope, patient_id),
      else: {:error, :unauthorized}
  end

  defp do_analyze(scope, patient_id) do
    transact_tenant(scope, fn ->
      case Patient |> patient_scoped(scope) |> Repo.get(patient_id) do
        nil -> {:error, :unauthorized}
        patient -> analyze_loaded(scope, patient)
      end
    end)
  end

  defp analyze_loaded(scope, patient) do
    cond do
      not has_active_frameworks?(patient) -> {:error, :no_active_frameworks}
      active = active_analysis(scope, patient.id) -> {:ok, active}
      true -> insert_pending(scope, patient.id)
    end
  end

  defp insert_pending(scope, patient_id) do
    attrs = %{tenant_id: scope.tenant.id, user_id: scope.user.id, patient_id: patient_id}

    case attrs |> Analysis.insert_changeset() |> Repo.insert() do
      {:ok, analysis} ->
        Oban.insert!(GenerateSuggestionsWorker.new(job_args(analysis)))
        {:ok, analysis}

      {:error, changeset} ->
        resolve_active_race(scope, patient_id, changeset)
    end
  end

  # SÓ trata como corrida do índice parcial "1 ativa por paciente". Qualquer outro erro
  # (FK, validação, outra constraint) é bug real e sobe como {:error, changeset} — nunca
  # vira {:ok, nil} silencioso. O insert falho roda em savepoint (unique_constraint
  # declarado), então a transação externa segue viva e o active_analysis abaixo funciona.
  defp resolve_active_race(scope, patient_id, changeset) do
    if active_constraint_error?(changeset) do
      case active_analysis(scope, patient_id) do
        # corrida real: a outra requisição venceu — devolve a ativa (idempotente)
        %Analysis{} = active -> {:ok, active}
        # constraint disparou mas não há ativa agora (caso degenerado): devolve o erro real
        nil -> {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  # O índice parcial é :analyses_one_active_per_patient (ver migration). Quando ele dispara,
  # o erro vem na 1ª coluna do unique_constraint com constraint_name batendo.
  defp active_constraint_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      opts[:constraint] == :unique and opts[:constraint_name] == "analyses_one_active_per_patient"
    end)
  end

  defp has_active_frameworks?(patient) do
    Repo.exists?(from(pf in PatientFramework, where: pf.patient_id == ^patient.id))
  end

  defp active_analysis(scope, patient_id) do
    Analysis
    |> scoped(scope)
    |> where([a], a.patient_id == ^patient_id and a.generation_status in @active_statuses)
    |> Repo.one()
  end

  def get_analysis(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> Analysis |> scoped(scope) |> Repo.get(id) end)

  def get_analysis!(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> Analysis |> scoped(scope) |> Repo.get!(id) end)

  # --- pubsub / job ---
  def subscribe(analysis_id), do: Phoenix.PubSub.subscribe(@pubsub, "analysis:#{analysis_id}")

  def broadcast(%Analysis{} = a),
    do: Phoenix.PubSub.broadcast(@pubsub, "analysis:#{a.id}", {:analysis_updated, a})

  def job_args(%Analysis{} = a),
    do: %{analysis_id: a.id, user_id: a.user_id, tenant_id: a.tenant_id}

  # scope por praticante: tenant_id + user_id (vale pra Analysis e Suggestion)
  defp scoped(query, scope),
    do: from(x in query, where: x.tenant_id == ^scope.tenant.id and x.user_id == ^scope.user.id)

  defp patient_scoped(query, scope),
    do: from(p in query, where: p.tenant_id == ^scope.tenant.id and p.user_id == ^scope.user.id)

  defdelegate transact_tenant(scope, fun), to: Repo
end
```

> O `GenerateSuggestionsWorker` ainda não existe (Task 14). `GenerateSuggestionsWorker.new/1` é referência de módulo — compila, mas o `assert_enqueued`/`perform_job` só funcionam após a Task 14. Para esta task, **comentar temporariamente** a linha do `assert_enqueued` nos 3 testes que a usam **NÃO é necessário**: o worker é referenciado mas o teste `analyze_patient cria pending` precisa dele para enfileirar. **Implemente um stub mínimo do worker agora** para destravar o enqueue:
>
> Criar `lib/ravanshenasi/analyses/generate_suggestions_worker.ex` mínimo (a Task 14 completa o `perform`):
> ```elixir
> defmodule Ravanshenasi.Analyses.GenerateSuggestionsWorker do
>   use Oban.Worker, queue: :ai, max_attempts: 3
>   @impl Oban.Worker
>   def perform(%Oban.Job{}), do: :ok
> end
> ```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/analyses_test.exs -v`
Expected: PASS (6 testes). Oban em `:manual` — `assert_enqueued`/`all_enqueued` veem o job sem executá-lo.

---

## Task 12: `Analyses` — `mark_generating`/`complete`/`fail` (idempotentes) + `list_suggestions`

**Files:**
- Modify: `lib/ravanshenasi/analyses.ex`
- Test: `test/ravanshenasi/analyses_test.exs`

**Idempotência (Oban é at-least-once):** se o job reexecutar após sucesso, NÃO pode regredir nem duplicar.
- `mark_generating` só transiciona de `pending`/`generating` → `generating`; em `done`/`error` é **no-op** (devolve a análise inalterada, sem regredir).
- `complete` em análise **já `done`** é **no-op** (`{:ok, analysis}` sem reinserir cards).
- `list_suggestions/2` entra **nesta task** (em vez da 13) pra esta task fechar verde sozinha — `complete` valida os cards via ela.

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/analyses_test.exs`:

```elixir
  @suggestions [
    %{framework: "TCC", justification: "j1", techniques: ["t1"], watch_out: "w1"},
    %{framework: "ACT", justification: "j2", techniques: ["t2", "t3"], watch_out: "w2"}
  ]

  test "mark_generating → generating + broadcast", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    Analyses.subscribe(a.id)
    assert {:ok, a} = Analyses.mark_generating(s, a)
    assert a.generation_status == :generating
    assert_receive {:analysis_updated, %{generation_status: :generating}}
  end

  test "complete grava done + insere N suggestions + broadcast", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    Analyses.subscribe(a.id)
    assert {:ok, done} = Analyses.complete(s, a, @suggestions, "stub:stub-model")
    assert done.generation_status == :done
    assert done.model_used == "stub:stub-model"
    cards = Analyses.list_suggestions(s, %{id: a.id})
    assert length(cards) == 2
    assert Enum.map(cards, & &1.framework_name) |> Enum.sort() == ["ACT", "TCC"]
    assert Enum.all?(cards, &(&1.status == :suggested))
    assert_receive {:analysis_updated, %{generation_status: :done}}
  end

  test "fail grava error + error_reason", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    assert {:ok, a} = Analyses.fail(s, a, :invalid_json)
    assert a.generation_status == :error
    assert a.error_reason =~ "invalid_json"
  end

  test "complete 2x (reexecução de job) NÃO duplica cards", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    {:ok, _} = Analyses.complete(s, a, @suggestions, "stub:m")
    {:ok, again} = Analyses.complete(s, a, @suggestions, "stub:m")
    assert again.generation_status == :done
    assert length(Analyses.list_suggestions(s, %{id: a.id})) == 2
  end

  test "mark_generating em análise já done NÃO regride", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    {:ok, _} = Analyses.complete(s, a, @suggestions, "stub:m")
    assert {:ok, still_done} = Analyses.mark_generating(s, a)
    assert still_done.generation_status == :done
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/analyses_test.exs -v`
Expected: FAIL — `function Ravanshenasi.Analyses.mark_generating/2 is undefined`.

- [ ] **Step 3: Implementar**

Acrescentar a `lib/ravanshenasi/analyses.ex` (antes do bloco pubsub/job):

```elixir
  # --- internos (worker, scope reconstruído) — recarregam, não confiam no struct.
  # Idempotentes: Oban é at-least-once, então reexecução não pode regredir nem duplicar. ---

  @doc "Marca generating. No-op em done/error (não regride). Broadcast quando aplicável."
  def mark_generating(%Scope{} = scope, %{id: id}) do
    res =
      transact_tenant(scope, fn ->
        case Analysis |> scoped(scope) |> Repo.get(id) do
          nil ->
            {:error, :unauthorized}

          %Analysis{generation_status: st} = a when st in @active_statuses ->
            a |> Analysis.status_changeset(%{generation_status: :generating}) |> Repo.update()

          # done/error são terminais: não regride numa reexecução de job
          %Analysis{} = a ->
            {:ok, a}
        end
      end)

    with {:ok, a} <- res, do: broadcast(a)
    res
  end

  def fail(%Scope{} = scope, %{id: id}, reason),
    do: set_status(scope, id, %{generation_status: :error, error_reason: inspect(reason)})

  @doc """
  Marca done e insere as N suggestions (tenant/user derivados da analysis), depois broadcast.
  Idempotente: análise já `done` é no-op (não reinsere cards numa reexecução de job).
  """
  def complete(%Scope{} = scope, %{id: id}, suggestions, model_used) do
    res =
      transact_tenant(scope, fn ->
        case Analysis |> scoped(scope) |> Repo.get(id) do
          nil ->
            {:error, :unauthorized}

          # já concluída: idempotente — não reinsere (Oban at-least-once)
          %Analysis{generation_status: :done} = a ->
            {:ok, a}

          analysis ->
            {:ok, done} =
              analysis
              |> Analysis.status_changeset(%{generation_status: :done, model_used: model_used})
              |> Repo.update()

            insert_suggestions(done, suggestions)
            {:ok, done}
        end
      end)

    with {:ok, a} <- res, do: broadcast(a)
    res
  end

  @doc "Cards de uma análise (do dono). Read escopa por id — struct alheio não retorna nada."
  def list_suggestions(%Scope{} = scope, %{id: analysis_id}) do
    transact_tenant(scope, fn ->
      Suggestion
      |> scoped(scope)
      |> where([sg], sg.analysis_id == ^analysis_id)
      |> order_by([sg], asc: sg.inserted_at)
      |> Repo.all()
    end)
  end

  defp insert_suggestions(%Analysis{} = analysis, suggestions) do
    Enum.each(suggestions, fn s ->
      %{
        tenant_id: analysis.tenant_id,
        user_id: analysis.user_id,
        analysis_id: analysis.id,
        framework_name: s.framework,
        justification: s.justification,
        techniques: s.techniques,
        watch_out: s.watch_out,
        status: :suggested
      }
      |> Suggestion.insert_changeset()
      |> Repo.insert!()
    end)
  end

  defp set_status(scope, id, changes) do
    res =
      transact_tenant(scope, fn ->
        case Analysis |> scoped(scope) |> Repo.get(id) do
          nil -> {:error, :unauthorized}
          a -> a |> Analysis.status_changeset(changes) |> Repo.update()
        end
      end)

    with {:ok, a} <- res, do: broadcast(a)
    res
  end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/analyses_test.exs -v`
Expected: PASS — testes da Task 11 + os 5 desta task (incl. idempotência). Esta task fecha verde sozinha (`list_suggestions` já está aqui).

---

## Task 13: `Analyses` — `list_analyses` + `save`/`discard`

**Files:**
- Modify: `lib/ravanshenasi/analyses.ex`
- Test: `test/ravanshenasi/analyses_test.exs`

Reads **escopam** por `tenant_id`+`user_id` (struct alheio não retorna dado). `save`/`discard` recarregam por id antes de mudar o status. (`list_suggestions/2` já veio na Task 12.)

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/analyses_test.exs`:

```elixir
  test "list_analyses do paciente, do dono; não vaza pra outro therapist do tenant" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})
    fw = Frameworks.list_frameworks(a) |> hd()
    :ok = Patients.activate_framework(a, pa, fw)
    {:ok, an} = Analyses.analyze_patient(a, pa)

    assert Enum.map(Analyses.list_analyses(a, %{id: pa.id}), & &1.id) == [an.id]
    # B passa o id do paciente de A — não enxerga as análises de A
    assert Analyses.list_analyses(b, %{id: pa.id}) == []
  end

  test "list_suggestions não vaza pra outro profissional", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    {:ok, _} = Analyses.complete(s, a, @suggestions, "stub:m")

    assert length(Analyses.list_suggestions(s, %{id: a.id})) == 2
    other = user_scope_fixture()
    assert Analyses.list_suggestions(other, %{id: a.id}) == []
  end

  test "save_suggestion / discard_suggestion mudam status; alheio → :unauthorized", %{scope: s, patient: p} do
    {:ok, a} = Analyses.analyze_patient(s, p)
    {:ok, _} = Analyses.complete(s, a, @suggestions, "stub:m")
    [c1, c2] = Analyses.list_suggestions(s, %{id: a.id})

    assert {:ok, saved} = Analyses.save_suggestion(s, c1)
    assert saved.status == :saved
    assert {:ok, disc} = Analyses.discard_suggestion(s, c2)
    assert disc.status == :discarded

    other = user_scope_fixture()
    assert {:error, :unauthorized} = Analyses.save_suggestion(other, c1)
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/analyses_test.exs -v`
Expected: FAIL — `function Ravanshenasi.Analyses.list_analyses/2 is undefined`.

- [ ] **Step 3: Implementar**

Acrescentar a `lib/ravanshenasi/analyses.ex`:

```elixir
  @doc "Histórico de análises do paciente (do dono), mais recentes primeiro. Read escopa por id."
  def list_analyses(%Scope{} = scope, %{id: patient_id}) do
    transact_tenant(scope, fn ->
      Analysis
      |> scoped(scope)
      |> where([a], a.patient_id == ^patient_id)
      |> order_by([a], desc: a.inserted_at)
      |> Repo.all()
    end)
  end

  def save_suggestion(%Scope{} = scope, %{id: id}), do: set_suggestion_status(scope, id, :saved)

  def discard_suggestion(%Scope{} = scope, %{id: id}),
    do: set_suggestion_status(scope, id, :discarded)

  defp set_suggestion_status(scope, id, status) do
    transact_tenant(scope, fn ->
      case Suggestion |> scoped(scope) |> Repo.get(id) do
        nil -> {:error, :unauthorized}
        sg -> sg |> Suggestion.status_changeset(%{status: status}) |> Repo.update()
      end
    end)
  end
```

- [ ] **Step 4: Rodar e ver passar (arquivo inteiro)**

Run: `mix test test/ravanshenasi/analyses_test.exs -v`
Expected: PASS — todos os testes das Tasks 11, 12 e 13.

---

## Task 14: `GenerateSuggestionsWorker` (completo)

**Files:**
- Modify: `lib/ravanshenasi/analyses/generate_suggestions_worker.ex` (substitui o stub da Task 11)
- Test: `test/ravanshenasi/analyses/generate_suggestions_worker_test.exs`

Espelha `GenerateSoapWorker`: reconstrói o scope validando `user↔tenant`, carrega a análise por API escopada, `mark_generating`, monta input via contexts escopados (sequencial, **fora de transação** — pode chamar contexts), `AI.generate_suggestions` fora de transação, `done`/`error` (último attempt), `discard` se não achar.

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ravanshenasi/analyses/generate_suggestions_worker_test.exs`:

```elixir
defmodule Ravanshenasi.Analyses.GenerateSuggestionsWorkerTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Analyses, Frameworks, Patients}
  alias Ravanshenasi.Analyses.GenerateSuggestionsWorker

  @json ~s([{"framework":"TCC","justification":"j","techniques":["t"],"watch_out":"w"},
            {"framework":"ACT","justification":"j2","techniques":["t2"],"watch_out":"w2"}])

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria", birth_date: ~D[1990-01-01]})
    fw = Frameworks.list_frameworks(scope) |> hd()
    :ok = Patients.activate_framework(scope, patient, fw)
    {:ok, analysis} = Analyses.analyze_patient(scope, patient)
    %{scope: scope, analysis: analysis}
  end

  test "sucesso → analysis done + suggestions", %{scope: s, analysis: a} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:good],
      providers: %{good: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: @json, model: "good"}}
    )

    assert :ok = perform_job(GenerateSuggestionsWorker, Analyses.job_args(a))
    done = Analyses.get_analysis(s, a.id)
    assert done.generation_status == :done
    assert done.model_used == "good:good"
    assert length(Analyses.list_suggestions(s, %{id: a.id})) == 2
  end

  test "reexecução de job já concluído é no-op (não duplica cards)", %{scope: s, analysis: a} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:good],
      providers: %{good: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: @json, model: "good"}}
    )

    assert :ok = perform_job(GenerateSuggestionsWorker, Analyses.job_args(a))
    assert :ok = perform_job(GenerateSuggestionsWorker, Analyses.job_args(a))
    assert length(Analyses.list_suggestions(s, %{id: a.id})) == 2
  end

  test "JSON inválido no último attempt → analysis error", %{scope: s, analysis: a} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad],
      providers: %{bad: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: "sem json", model: "bad"}}
    )

    assert :ok = perform_job(GenerateSuggestionsWorker, Analyses.job_args(a), attempt: 3)
    assert Analyses.get_analysis(s, a.id).generation_status == :error
  end

  test "JSON inválido com attempt < max → {:error, _} (retry)", %{analysis: a} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)

    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad],
      providers: %{bad: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, content: "sem json", model: "bad"}}
    )

    assert {:error, :invalid_json} = perform_job(GenerateSuggestionsWorker, Analyses.job_args(a), attempt: 1)
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/analyses/generate_suggestions_worker_test.exs -v`
Expected: FAIL — o worker stub devolve `:ok` sem mudar nada, então `done.generation_status` ainda é `:pending` (assert quebra).

- [ ] **Step 3: Implementar (substituir o stub)**

Substituir `lib/ravanshenasi/analyses/generate_suggestions_worker.ex` por:

```elixir
defmodule Ravanshenasi.Analyses.GenerateSuggestionsWorker do
  @moduledoc "Oban worker that calls the AI facade to suggest therapy approaches for an analysis."

  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Ravanshenasi.Accounts.{Scope, Tenant, User}
  alias Ravanshenasi.{AI, Analyses, Patients, Records}
  alias Ravanshenasi.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max}) do
    %{"analysis_id" => aid, "user_id" => uid, "tenant_id" => tid} = args

    with {:ok, scope} <- build_scope(uid, tid),
         %Analyses.Analysis{} = analysis <- Analyses.get_analysis(scope, aid) do
      process(scope, analysis, attempt, max)
    else
      nil -> {:discard, :not_found}
      {:error, :not_found} -> {:discard, :not_found}
    end
  end

  # Terminal (done/error): o job já foi concluído numa execução anterior (Oban é
  # at-least-once). Não reprocessa a IA. O context também é idempotente como rede de segurança.
  defp process(_scope, %Analyses.Analysis{generation_status: st}, _attempt, _max)
       when st in [:done, :error],
       do: :ok

  defp process(scope, analysis, attempt, max) do
    {:ok, _} = Analyses.mark_generating(scope, analysis)
    input = build_input(scope, analysis)

    case AI.generate_suggestions(input) do
      {:ok, %{suggestions: suggestions, provider: provider, model: model}} ->
        {:ok, _} = Analyses.complete(scope, analysis, suggestions, "#{provider}:#{model}")
        :ok

      {:error, reason} when attempt >= max ->
        {:ok, _} = Analyses.fail(scope, analysis, reason)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_scope(uid, tid) do
    Repo.with_auth_bypass(fn ->
      # `%User{tenant_id: ^tid}` casa só se o user PERTENCE ao tenant do job.
      with %User{tenant_id: ^tid} = user <- Repo.get(User, uid),
           %Tenant{} = tenant <- Repo.get(Tenant, tid) do
        {:ok, Scope.for_user(user) |> Scope.put_tenant(tenant)}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  defp build_input(scope, analysis) do
    patient = Patients.get_patient!(scope, analysis.patient_id)

    %{
      patient: patient,
      frameworks: Patients.list_patient_frameworks(scope, patient),
      recent_records: Records.recent_done_records(scope, %{id: patient.id})
    }
  end
end
```

> No worker, `build_input` chama contexts **fora de transação** (sequencial), então pode usar `Patients.*`/`Records.*` à vontade — sem o problema de aninhamento.

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/analyses/generate_suggestions_worker_test.exs -v`
Expected: PASS (3 testes).

---

## Task 15: `PatientLive.Show` — botão, cards, save/discard, PubSub, estados

**Files:**
- Modify: `lib/ravanshenasi_web/live/patient_live/show.ex`
- Test: `test/ravanshenasi_web/live/patient_live_test.exs` (criar se não existir)

UI sem rota nova: botão "Analisar paciente", empty state sem frameworks, "Analisando…", cards com save/discard, erro + "tentar de novo". IDs estáveis. PubSub atualiza em tempo real.

- [ ] **Step 1: Escrever o teste que falha**

Criar/!acrescentar `test/ravanshenasi_web/live/patient_live_test.exs`:

```elixir
defmodule RavanshenasiWeb.PatientLiveTest do
  use RavanshenasiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Analyses, Frameworks, Patients}

  setup %{conn: conn} do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    %{conn: log_in_user(conn, scope.user), scope: scope, patient: patient}
  end

  @suggestions [
    %{framework: "TCC", justification: "j1", techniques: ["t1"], watch_out: "w1"},
    %{framework: "ACT", justification: "j2", techniques: ["t2"], watch_out: "w2"}
  ]

  defp activate_one(scope, patient) do
    fw = Frameworks.list_frameworks(scope) |> hd()
    :ok = Patients.activate_framework(scope, patient, fw)
  end

  test "sem frameworks: analisar mostra empty state", %{conn: conn, patient: p} do
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}")
    lv |> element("#analyze-patient-button") |> render_click()
    assert has_element?(lv, "#no-frameworks-warning")
  end

  test "com frameworks: analisar mostra 'Analisando'", %{conn: conn, scope: s, patient: p} do
    activate_one(s, p)
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}")
    lv |> element("#analyze-patient-button") |> render_click()
    assert has_element?(lv, "#analysis-generating")
  end

  test "broadcast done renderiza os cards", %{conn: conn, scope: s, patient: p} do
    activate_one(s, p)
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}")
    lv |> element("#analyze-patient-button") |> render_click()

    [analysis] = Analyses.list_analyses(s, %{id: p.id})
    {:ok, _} = Analyses.complete(s, analysis, @suggestions, "stub:stub-model")

    assert has_element?(lv, "#suggestions")
    assert has_element?(lv, "h4", "TCC")
  end

  test "salvar um card muda o estado", %{conn: conn, scope: s, patient: p} do
    activate_one(s, p)
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}")
    lv |> element("#analyze-patient-button") |> render_click()
    [analysis] = Analyses.list_analyses(s, %{id: p.id})
    {:ok, _} = Analyses.complete(s, analysis, @suggestions, "stub:m")

    [c1, _] = Analyses.list_suggestions(s, %{id: analysis.id})
    lv |> element("#save-suggestion-#{c1.id}") |> render_click()
    assert Analyses.list_suggestions(s, %{id: analysis.id}) |> Enum.any?(&(&1.status == :saved))
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi_web/live/patient_live_test.exs -v`
Expected: FAIL — `#analyze-patient-button` não existe no render atual.

- [ ] **Step 3: Implementar**

Substituir `lib/ravanshenasi_web/live/patient_live/show.ex` por (mantém frameworks/inactivate existentes; acrescenta a seção de análise):

```elixir
defmodule RavanshenasiWeb.PatientLive.Show do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Analyses
  alias Ravanshenasi.Frameworks
  alias Ravanshenasi.Patients

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Patients.get_patient(scope, id) do
      nil ->
        {:ok,
         socket
         |> Phoenix.LiveView.put_flash(:error, gettext("Patient not found"))
         |> Phoenix.LiveView.push_navigate(to: ~p"/pacientes")}

      patient ->
        {:ok,
         socket
         |> assign(patient: patient, no_frameworks_warning: false)
         |> load_frameworks()
         |> load_analysis()}
    end
  end

  @impl true
  def handle_event("inactivate", _, socket) do
    scope = socket.assigns.current_scope

    case Patients.inactivate_patient(scope, socket.assigns.patient) do
      {:ok, patient} ->
        {:noreply,
         socket |> assign(patient: patient) |> put_flash(:info, gettext("Patient inactivated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not inactivate patient"))}
    end
  end

  @impl true
  def handle_event("toggle-framework", %{"id" => fw_id, "on" => on}, socket) do
    scope = socket.assigns.current_scope
    framework = Frameworks.get_framework!(scope, fw_id)

    if on == "true" do
      Patients.activate_framework(scope, socket.assigns.patient, framework)
    else
      Patients.deactivate_framework(scope, socket.assigns.patient, framework)
    end

    {:noreply, load_frameworks(socket)}
  end

  @impl true
  def handle_event("analyze", _, socket) do
    scope = socket.assigns.current_scope

    case Analyses.analyze_patient(scope, socket.assigns.patient) do
      {:ok, analysis} ->
        Analyses.subscribe(analysis.id)

        {:noreply,
         assign(socket,
           analysis: analysis,
           suggestions: load_suggestions(scope, analysis),
           no_frameworks_warning: false
         )}

      {:error, :no_active_frameworks} ->
        {:noreply, assign(socket, analysis: nil, suggestions: [], no_frameworks_warning: true)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not allowed"))}

      # corrida rara do índice parcial pode devolver {:error, changeset}; não quebra a UI
      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not start the analysis"))}
    end
  end

  @impl true
  def handle_event("save-suggestion", %{"id" => id}, socket) do
    case Analyses.save_suggestion(socket.assigns.current_scope, %{id: id}) do
      {:ok, _} -> {:noreply, reload_suggestions(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not update suggestion"))}
    end
  end

  @impl true
  def handle_event("discard-suggestion", %{"id" => id}, socket) do
    case Analyses.discard_suggestion(socket.assigns.current_scope, %{id: id}) do
      {:ok, _} -> {:noreply, reload_suggestions(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not update suggestion"))}
    end
  end

  @impl true
  def handle_info({:analysis_updated, analysis}, socket) do
    scope = socket.assigns.current_scope
    {:noreply, assign(socket, analysis: analysis, suggestions: load_suggestions(scope, analysis))}
  end

  defp load_frameworks(socket) do
    scope = socket.assigns.current_scope
    all = Frameworks.list_frameworks(scope)

    active_ids =
      Patients.list_patient_frameworks(scope, socket.assigns.patient)
      |> MapSet.new(& &1.id)

    assign(socket, all_frameworks: all, active_ids: active_ids)
  end

  defp load_analysis(socket) do
    scope = socket.assigns.current_scope
    analysis = Analyses.list_analyses(scope, %{id: socket.assigns.patient.id}) |> List.first()

    if analysis && analysis.generation_status in [:pending, :generating],
      do: Analyses.subscribe(analysis.id)

    assign(socket, analysis: analysis, suggestions: load_suggestions(scope, analysis))
  end

  defp reload_suggestions(socket) do
    scope = socket.assigns.current_scope
    assign(socket, suggestions: load_suggestions(scope, socket.assigns.analysis))
  end

  defp load_suggestions(scope, %{generation_status: :done} = analysis),
    do: Analyses.list_suggestions(scope, %{id: analysis.id})

  defp load_suggestions(_scope, _analysis), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>{@patient.name}</.header>
      <p>{@patient.chief_complaint}</p>

      <h3>{gettext("Lines of thought")}</h3>
      <ul>
        <li :for={f <- @all_frameworks}>
          <label>
            <input
              type="checkbox"
              checked={MapSet.member?(@active_ids, f.id)}
              phx-click="toggle-framework"
              phx-value-id={f.id}
              phx-value-on={to_string(not MapSet.member?(@active_ids, f.id))}
            />
            {f.name}
          </label>
        </li>
      </ul>

      <section id="analysis-section">
        <h3>{gettext("Approach suggestions")}</h3>
        <.button id="analyze-patient-button" phx-click="analyze">
          {gettext("Analyze patient")}
        </.button>

        <p :if={@no_frameworks_warning} id="no-frameworks-warning">
          {gettext("Configure lines of thought for this patient before analyzing.")}
        </p>

        <p
          :if={@analysis && @analysis.generation_status in [:pending, :generating]}
          id="analysis-generating"
        >
          {gettext("Analyzing…")}
        </p>

        <div :if={@analysis && @analysis.generation_status == :error} id="analysis-error">
          <p>{gettext("Analysis failed.")}</p>
          <.button id="retry-analysis-button" phx-click="analyze">
            {gettext("Try again")}
          </.button>
        </div>

        <div :if={@analysis && @analysis.generation_status == :done} id="suggestions">
          <div :for={s <- @suggestions} id={"suggestion-#{s.id}"} class="card">
            <h4>{s.framework_name}</h4>
            <p>{s.justification}</p>
            <ul>
              <li :for={t <- s.techniques}>{t}</li>
            </ul>
            <p>{s.watch_out}</p>
            <span id={"suggestion-status-#{s.id}"}>{s.status}</span>
            <.button id={"save-suggestion-#{s.id}"} phx-click="save-suggestion" phx-value-id={s.id}>
              {gettext("Save")}
            </.button>
            <.button
              id={"discard-suggestion-#{s.id}"}
              phx-click="discard-suggestion"
              phx-value-id={s.id}
            >
              {gettext("Discard")}
            </.button>
          </div>
        </div>
      </section>

      <.button navigate={~p"/pacientes/#{@patient.id}/editar"}>{gettext("Edit")}</.button>
      <.button
        :if={@patient.status != :inactive}
        phx-click="inactivate"
        data-confirm={gettext("Inactivate this patient?")}
      >
        {gettext("Inactivate patient")}
      </.button>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi_web/live/patient_live_test.exs -v`
Expected: PASS (4 testes).

---

## Final: validação da fatia inteira

- [ ] **Step 1: Suite completa**

Run: `mix test`
Expected: TODOS verdes (os ~216 anteriores + os novos da Fatia 3). Zero falhas.

- [ ] **Step 2: precommit (format + credo + test)**

Run: `mix precommit`
Expected: verde. Se o Credo apontar "nesting too deep" / "function too long" em `Analyses` ou na LiveView, extrair helper privado (como a Fatia 2 fez com `finalize_failure_reason/2`) e rodar de novo.

- [ ] **Step 3: Conferir gettext (i18n)**

Run: `mix gettext.extract` (se o projeto usa; senão pular)
Expected: novas strings (`Analyze patient`, `Analyzing…`, `Approach suggestions`, etc.) extraídas. **Não traduzir aqui** — só garantir que extraiu sem erro.

- [ ] **Step 4: Deixar pro usuário commitar**

**NÃO commitar.** Reportar: arquivos criados/modificados, migrations aplicadas, contagem de testes, e qualquer pendência. A working tree fica pronta pro usuário revisar e commitar.

---

## Self-Review (checagem do plano contra a spec)

**Spec coverage:**
- §3 (generalização IA): Tasks 1 (`chat/1`), 2 (`suggestions_messages`), 3 (`parse`), 4 (`generate_suggestions`). ✅
- §4 (modelo de dados): Tasks 5 (unique patients), 6 (analyses), 7 (suggestions), 8–9 (schemas). FK composta 3 colunas em analyses.patient_id e suggestions.analysis_id ✅; unique `(id,tenant_id,user_id)` ✅; índice parcial "1 ativa" ✅; RLS ✅.
- §5 (worker): Task 14 — scope reconstruído validando user↔tenant, IA fora de transação, done/error/discard, retry, **short-circuit em terminal (done/error) contra reexecução at-least-once**. ✅
- §6 (contexts): Tasks 11 (analyze_patient idempotente + no_frameworks + race **só na constraint certa** + get), 12 (mark/complete/fail **idempotentes** + list_suggestions + insert derivando tenant/user), 13 (list_analyses/save/discard). `recent_done_records` em Task 10 (order by session.date). ✅
- §7 (autorização): clinical_access? + dono em tudo; reads E writes escopam — Tasks 11–13 + testes de isolamento (incl. `list`). ✅
- §8 (edge cases): unauthorized, invalid_json→retry→error, no_active_frameworks, idempotência, discard not_found — cobertos por testes nas Tasks 11/13/14. ✅
- §9–10 (real-time/UI): Task 15 — PubSub, "Analisando", cards, erro+tentar de novo, empty state, save/discard, IDs estáveis. ✅
- §11 (testes): async:false onde toca transact_tenant/Oban; Oban :manual; stub com JSON. ✅
- §14 (DoD): cada item mapeia a uma task. ✅

**Placeholder scan:** sem TBD/TODO; todo step de código tem o código completo; comandos com expected output. ✅

**Type consistency:** `chat/1`→`%{content, provider, model}`; `generate_suggestions/1`→`%{suggestions, provider, model}`; `parse/1`→`[%{framework, justification, techniques, watch_out}]` (chaves atom); `complete/4` mapeia `s.framework`→`framework_name`; `job_args`→`%{analysis_id, user_id, tenant_id}`; broadcast `{:analysis_updated, analysis}`; tópico `"analysis:<id>"`; índice parcial `:analyses_one_active_per_patient` (mesmo nome em migration §6 e changeset Task 8). ✅

**Nota de dependência cruzada:** Task 11 cria um **stub** do worker (`perform/1 → :ok`) só pra destravar `Oban.insert!`/`assert_enqueued`; Task 14 substitui pelo `perform` completo. Cada task de `Analyses` (11, 12, 13) fecha verde sozinha — `list_suggestions/2` foi pra Task 12 (junto de `complete`, que a usa nos asserts), então não há mais a dependência 12→13.

**Idempotência (Oban at-least-once) — findings de review aplicados:**
- `mark_generating` não regride `done`/`error`; `complete` em `done` é no-op (não reinsere cards). Worker faz short-circuit em terminal antes de gastar IA. Testes: "complete 2x não duplica", "mark_generating em done não regride", "reexecução de job é no-op".
- `insert_pending` só converte `{:error, changeset}` em `{:ok, active}` **quando** o erro é a constraint `:analyses_one_active_per_patient` E há ativa; senão devolve o `{:error, changeset}` real (sem `{:ok, nil}` mascarando bug).
- LiveView `analyze`/`save`/`discard` tratam `{:error, _}` com flash (não silenciam stale/unauthorized).
