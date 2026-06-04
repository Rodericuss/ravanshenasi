# Fatia 2 — Sessões + Prontuário SOAP (IA) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.
>
> **WORKFLOW DESTE PROJETO (override):** trabalhar **direto na `main`, sem branches**. Os agentes **NÃO commitam** — cada task termina implementada + testada (verde), e o working tree fica para o **usuário** commitar. Sem `git add`/`git commit` pelos agentes. (Ver memória `work-on-main-leave-commits-to-user`.)

**Goal:** Registro de sessões terapêuticas e geração automática de prontuário SOAP por IA (assíncrona via Oban, com fallback entre providers OpenAI-compatible) ao finalizar uma sessão.

**Architecture:** `sessions` + `records` (RLS por tenant + scope por user_id + FK compostas, padrão Fatia 1). Finalizar uma sessão (UPDATE condicional `WHERE status=:draft`) cria o record `pending` e enfileira um job Oban; o worker reconstrói o scope do dono, monta o prompt SOAP (perfil + linhas ativas + 3 sessões anteriores + notas), chama `Ravanshenasi.AI.generate_soap` (registry de providers protocolo-OpenAI com fallback), salva o resultado e faz broadcast PubSub; a LiveView atualiza em tempo real.

**Tech Stack:** Elixir 1.19 · Phoenix 1.8.7 · LiveView 1.1 · Ecto/Postgrex · TimescaleDB pg17 · **Oban ~> 2.23** · `req` (cliente HTTP).

**Spec:** `docs/superpowers/specs/2026-06-04-fatia-2-sessoes-prontuario-soap-design.md`

---

## Convenções (da Fatia 1)

- **Binary IDs**, `Ecto.Enum` (coluna string), FK composta via `references(:t, with: [tenant_id: :tenant_id])`.
- `Repo.transact_tenant(scope, fn)` (resultado cru; reset GUC no sucesso); `Repo.with_auth_bypass/1`; `Ravanshenasi.RLS.enable_tenant_rls(tabela)`.
- `Scope` (`%Scope{user, tenant}`, `clinical_access?/1`, `admin?/1`); `Patients.get_patient!/2`, `Patients.list_patient_frameworks/2`.
- Fixtures (`Ravanshenasi.AccountsFixtures`): `user_scope_fixture/0` (solo), `clinic_admin_scope_fixture/0`, `therapist_scope_fixture/1` (clínica). Paciente: `Patients.create_patient(scope, %{name: ...})`.
- **Testes que tocam `transact_tenant`/bypass no corpo → `use Ravanshenasi.DataCase, async: false`.**
- **NÃO confiar em struct (lição da Fatia 1):** toda função de **write** recebe `%{id: id}` e **recarrega o registro por query escopada** (`tenant_id` + `user_id`) antes de operar — nunca `Repo.update`/`delete` direto no struct do caller. RLS isola só por tenant; o scope no app é quem isola entre profissionais do mesmo tenant. (Aplicado nos snippets; siga o mesmo nas funções de Form/Index não detalhadas.)
- Comando: `mix test caminho:linha`. Rodar `mix test` ao fim de cada task. **NÃO commitar** (workflow acima).

---

## File Structure

**Criados:**
- `lib/ravanshenasi/ai.ex` · `lib/ravanshenasi/ai/client.ex` · `lib/ravanshenasi/ai/client/open_ai.ex` · `lib/ravanshenasi/ai/client/stub.ex` · `lib/ravanshenasi/ai/prompts.ex`
- `lib/ravanshenasi/sessions.ex` · `lib/ravanshenasi/sessions/session.ex`
- `lib/ravanshenasi/records.ex` · `lib/ravanshenasi/records/record.ex` · `lib/ravanshenasi/records/generate_soap_worker.ex`
- `lib/ravanshenasi_web/live/session_live/{index,show,form}.ex`
- migrations (oban, sessions, records).

**Estendidos:** `mix.exs` (dep oban), `lib/ravanshenasi/application.ex` (Oban no supervisor), `config/{config,test,runtime}.exs`, `lib/ravanshenasi_web/router.ex`, `test/support/data_case.ex` (Oban.Testing).

---

## Task 1: Oban — dep, config, supervisor, migration

**Files:**
- Modify: `mix.exs`, `lib/ravanshenasi/application.ex`, `config/config.exs`, `config/test.exs`, `test/support/data_case.ex`
- Create: `priv/repo/migrations/<ts>_add_oban_jobs_table.exs`

- [ ] **Step 1: Dep + deps.get**

Em `mix.exs`, no `defp deps`, adicione `{:oban, "~> 2.23"}`. Run: `mix deps.get`.

- [ ] **Step 2: Config base + test**

`config/config.exs` (antes do `import_config`):
```elixir
config :ravanshenasi, Oban,
  repo: Ravanshenasi.Repo,
  queues: [ai: 5]

config :ravanshenasi, Ravanshenasi.AI,
  order: [:openai],
  providers: %{
    openai: %{client: Ravanshenasi.AI.Client.OpenAI, base_url: nil, api_key: nil, model: nil}
  }
```
`config/test.exs` (adicione ao fim):
```elixir
# Oban: não roda jobs automaticamente em teste — usa Oban.Testing
config :ravanshenasi, Oban, testing: :manual

# IA: provider stub determinístico (sem rede)
config :ravanshenasi, Ravanshenasi.AI,
  order: [:stub],
  providers: %{stub: %{client: Ravanshenasi.AI.Client.Stub, behavior: :ok, model: "stub-model"}}
```

- [ ] **Step 3: Supervisor**

`lib/ravanshenasi/application.ex`, no `children`, adicione **depois** de `{Phoenix.PubSub, ...}`:
```elixir
      {Oban, Application.fetch_env!(:ravanshenasi, Oban)},
```

- [ ] **Step 4: Migration `oban_jobs`**

`mix ecto.gen.migration add_oban_jobs_table`, conteúdo:
```elixir
defmodule Ravanshenasi.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12)
  def down, do: Oban.Migration.down(version: 1)
end
```

- [ ] **Step 5: Oban.Testing no DataCase**

Em `test/support/data_case.ex`, dentro do `using do quote do ... end`, adicione (junto dos imports/aliases):
```elixir
      use Oban.Testing, repo: Ravanshenasi.Repo
```

- [ ] **Step 6: Migrar + compilar + suíte**

Run: `mix ecto.migrate && mix test`
Expected: compila com `{Oban, ...}` no supervisor; migration cria `oban_jobs`; **suíte existente continua verde** (Oban em `:manual` não interfere).

> `Ravanshenasi.AI.Client.OpenAI`/`Stub` ainda não existem — o config só os referencia como módulo (não chamado em boot). Se o compile reclamar de módulo inexistente, ignore: config é dado, não chamada. Se algum teste falhar por isso, ele só falha quando a IA é exercida (Tasks 4+).

---

## Task 2: Schema + migration `sessions`

**Files:**
- Create: `lib/ravanshenasi/sessions/session.ex`, migration `<ts>_create_sessions.exs`
- Test: `test/ravanshenasi/sessions/session_test.exs`

- [ ] **Step 1: Failing test**

```elixir
# test/ravanshenasi/sessions/session_test.exs
defmodule Ravanshenasi.Sessions.SessionTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Sessions.Session

  test "changeset válido" do
    cs = Session.changeset(%Session{}, %{date: ~U[2026-06-04 10:00:00Z], notes: "x", status: :draft})
    assert cs.valid?
  end

  test "status fora do enum é inválido" do
    cs = Session.changeset(%Session{}, %{status: :archived})
    refute cs.valid?
  end
end
```

- [ ] **Step 2: Run — FAIL** `mix test test/ravanshenasi/sessions/session_test.exs`

- [ ] **Step 3: Migration**

```elixir
# priv/repo/migrations/<ts>_create_sessions.exs
defmodule Ravanshenasi.Repo.Migrations.CreateSessions do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id,
          references(:users, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :restrict),
          null: false
      add :patient_id,
          references(:patients, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :delete_all),
          null: false

      add :date, :utc_datetime
      add :duration_minutes, :integer
      add :notes, :text
      add :status, :string, null: false, default: "draft"

      timestamps(type: :utc_datetime)
    end

    create index(:sessions, [:tenant_id, :user_id])
    create index(:sessions, [:tenant_id, :patient_id])
    create index(:sessions, [:tenant_id, :user_id, :status])
    # alvos das FKs compostas do record (Task 3)
    create unique_index(:sessions, [:id, :tenant_id, :user_id])
    create unique_index(:sessions, [:id, :patient_id])

    enable_tenant_rls("sessions")
  end
end
```

- [ ] **Step 4: Schema**

```elixir
# lib/ravanshenasi/sessions/session.ex
defmodule Ravanshenasi.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sessions" do
    field :date, :utc_datetime
    field :duration_minutes, :integer
    field :notes, :string
    field :status, Ecto.Enum, values: [:draft, :finalized], default: :draft

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User
    belongs_to :patient, Ravanshenasi.Patients.Patient

    timestamps(type: :utc_datetime)
  end

  @doc "Campos editáveis pelo profissional (tenant_id/user_id/patient_id setados server-side)."
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:date, :duration_minutes, :notes, :status])
    |> validate_required([])
  end
end
```

- [ ] **Step 5: Migrar + testar** `mix ecto.migrate && mix test test/ravanshenasi/sessions/session_test.exs` → 2 pass.

---

## Task 3: Schema + migration `records`

**Files:**
- Create: `lib/ravanshenasi/records/record.ex`, migration `<ts>_create_records.exs`
- Test: `test/ravanshenasi/records/record_test.exs`

- [ ] **Step 1: Failing test**

```elixir
# test/ravanshenasi/records/record_test.exs
defmodule Ravanshenasi.Records.RecordTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Records.Record

  test "content_changeset valida content" do
    cs = Record.content_changeset(%Record{}, %{content: "S:..\nO:..\nA:..\nP:.."})
    assert cs.valid?
  end

  test "status enum inválido" do
    cs = Record.status_changeset(%Record{}, %{generation_status: :weird})
    refute cs.valid?
  end
end
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Migration**

```elixir
# priv/repo/migrations/<ts>_create_records.exs
defmodule Ravanshenasi.Repo.Migrations.CreateRecords do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      # amarra dono+tenant à sessão
      add :user_id, :binary_id, null: false
      add :session_id, :binary_id, null: false
      add :patient_id, :binary_id, null: false

      add :content, :text
      add :reviewed, :boolean, null: false, default: false
      add :generation_status, :string, null: false, default: "pending"
      add :model_used, :string
      add :error_reason, :string

      timestamps(type: :utc_datetime)
    end

    # FKs compostas record↔session (integridade: record não pode divergir da sua sessão)
    execute(
      "ALTER TABLE records ADD CONSTRAINT records_session_owner_fkey FOREIGN KEY (session_id, tenant_id, user_id) REFERENCES sessions (id, tenant_id, user_id) ON DELETE CASCADE",
      "ALTER TABLE records DROP CONSTRAINT records_session_owner_fkey"
    )
    execute(
      "ALTER TABLE records ADD CONSTRAINT records_session_patient_fkey FOREIGN KEY (session_id, patient_id) REFERENCES sessions (id, patient_id) ON DELETE CASCADE",
      "ALTER TABLE records DROP CONSTRAINT records_session_patient_fkey"
    )

    create unique_index(:records, [:session_id])
    create index(:records, [:tenant_id, :user_id])
    create index(:records, [:tenant_id, :patient_id])

    enable_tenant_rls("records")
  end
end
```
> As FKs compostas vão via `execute/2` (SQL cru) porque referenciam um conjunto de colunas — mais simples que encadear `references(with:)` para dois alvos diferentes na mesma coluna `session_id`.

- [ ] **Step 4: Schema**

```elixir
# lib/ravanshenasi/records/record.ex
defmodule Ravanshenasi.Records.Record do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "records" do
    field :content, :string
    field :reviewed, :boolean, default: false
    field :generation_status, Ecto.Enum, values: [:pending, :generating, :done, :error], default: :pending
    field :model_used, :string
    field :error_reason, :string

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User
    belongs_to :session, Ravanshenasi.Sessions.Session
    belongs_to :patient, Ravanshenasi.Patients.Patient

    timestamps(type: :utc_datetime)
  end

  @doc "Edição do conteúdo (revisão)."
  def content_changeset(record, attrs) do
    record |> cast(attrs, [:content, :reviewed]) |> validate_required([:content])
  end

  @doc "Transições de status da geração."
  def status_changeset(record, attrs) do
    record |> cast(attrs, [:generation_status, :content, :model_used, :error_reason])
  end
end
```

- [ ] **Step 5: Migrar + testar** → 2 pass.

---

## Task 4: `AI.Client` behaviour + `Client.Stub`

**Files:**
- Create: `lib/ravanshenasi/ai/client.ex`, `lib/ravanshenasi/ai/client/stub.ex`
- Test: `test/ravanshenasi/ai/client/stub_test.exs`

- [ ] **Step 1: Failing test**

```elixir
# test/ravanshenasi/ai/client/stub_test.exs
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
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Behaviour + Stub**

```elixir
# lib/ravanshenasi/ai/client.ex
defmodule Ravanshenasi.AI.Client do
  @moduledoc "OpenAI-protocol chat client. Implementations talk to any compatible endpoint."
  @callback chat(provider_cfg :: map(), messages :: [map()], opts :: keyword()) ::
              {:ok, content :: String.t()} | {:error, reason :: term()}
end
```
```elixir
# lib/ravanshenasi/ai/client/stub.ex
defmodule Ravanshenasi.AI.Client.Stub do
  @moduledoc "Deterministic test client — no network. Behavior driven by provider cfg."
  @behaviour Ravanshenasi.AI.Client

  @impl true
  def chat(cfg, _messages, _opts) do
    case Map.get(cfg, :behavior, :ok) do
      :error -> {:error, Map.get(cfg, :error, :stub_error)}
      _ -> {:ok, Map.get(cfg, :content, "S: stub\nO: stub\nA: stub\nP: stub")}
    end
  end
end
```

- [ ] **Step 4: Run — PASS** (2).

---

## Task 5: `AI.Prompts` (build do prompt SOAP)

**Files:**
- Create: `lib/ravanshenasi/ai/prompts.ex`
- Test: `test/ravanshenasi/ai/prompts_test.exs`

- [ ] **Step 1: Failing test**

```elixir
# test/ravanshenasi/ai/prompts_test.exs
defmodule Ravanshenasi.AI.PromptsTest do
  use ExUnit.Case, async: true

  alias Ravanshenasi.AI.Prompts

  test "monta system + user com perfil, frameworks, sessões anteriores e notas atuais" do
    input = %{
      patient: %{name: "Maria", birth_date: ~D[1990-01-01], chief_complaint: "ansiedade", relevant_history: "—"},
      frameworks: [%{name: "TCC", description: "reestrutura pensamentos"}],
      previous_sessions: [%{date: ~U[2026-05-01 10:00:00Z], notes: "sessão anterior X"}],
      current_notes: "sessão de hoje Y"
    }

    assert [%{role: "system", content: sys}, %{role: "user", content: user}] = Prompts.soap_messages(input)
    assert sys =~ "SOAP"
    assert user =~ "Maria"
    assert user =~ "TCC"
    assert user =~ "sessão anterior X"
    assert user =~ "sessão de hoje Y"
    # `previous_sessions` traz só as anteriores; quem EXCLUI a sessão atual é
    # Sessions.recent_finalized/4 — testado direto no SessionsTest (Task 8). Aqui só
    # garantimos que ambas as fontes (anteriores + notas atuais) entram no prompt.
  end
end
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement**

```elixir
# lib/ravanshenasi/ai/prompts.ex
defmodule Ravanshenasi.AI.Prompts do
  @moduledoc "Builds the SOAP chat messages (OpenAI format) from clinical context."

  @system """
  Você é um assistente clínico especializado em psicologia. Gera prontuários clínicos \
  estruturados no formato SOAP (Subjetivo, Objetivo, Avaliação, Plano) a partir das notas \
  de sessão. Use linguagem clínica e de hipótese ("sugere", "indica", "observa-se"); \
  nunca faça diagnósticos definitivos e nunca invente informação fora das notas. \
  Responda apenas com o prontuário, sem introdução ou conclusão.
  """

  @spec soap_messages(map()) :: [map()]
  def soap_messages(%{patient: p, frameworks: fws, previous_sessions: prev, current_notes: notes}) do
    [
      %{role: "system", content: String.trim(@system)},
      %{role: "user", content: user_content(p, fws, prev, notes)}
    ]
  end

  defp user_content(p, fws, prev, notes) do
    """
    Perfil do paciente:
    - Nome: #{p.name}
    - Idade: #{age(p.birth_date)}
    - Queixa principal: #{p.chief_complaint}
    - Histórico relevante: #{p.relevant_history}

    Linhas de pensamento ativas:
    #{frameworks_block(fws)}

    Sessões anteriores (mais recentes):
    #{previous_block(prev)}

    Notas da sessão atual:
    #{notes}

    Gere o prontuário no formato SOAP (S/O/A/P).
    """
  end

  defp age(nil), do: "não informada"
  defp age(%Date{} = d), do: "#{div(Date.diff(Date.utc_today(), d), 365)} anos"

  defp frameworks_block([]), do: "- (nenhuma configurada)"
  defp frameworks_block(fws), do: Enum.map_join(fws, "\n", &"- #{&1.name}: #{&1.description}")

  defp previous_block([]), do: "- (nenhuma sessão anterior)"
  defp previous_block(prev), do: Enum.map_join(prev, "\n", &"- #{DateTime.to_date(&1.date)}: #{&1.notes}")
end
```

- [ ] **Step 4: Run — PASS**. (Ajuste o `refute` do teste se necessário; o ponto é que `current_notes` aparece só na seção "atual".)

> `Date.diff/2` usa hoje; em teste isso é determinístico o suficiente (asserts não checam o número exato da idade).

---

## Task 6: `Ravanshenasi.AI` (fachada + fallback)

**Files:**
- Create: `lib/ravanshenasi/ai.ex`
- Test: `test/ravanshenasi/ai_test.exs`

- [ ] **Step 1: Failing test (fallback)**

```elixir
# test/ravanshenasi/ai_test.exs
defmodule Ravanshenasi.AITest do
  use ExUnit.Case, async: false

  alias Ravanshenasi.AI
  alias Ravanshenasi.AI.Client.Stub

  defp input do
    %{patient: %{name: "X", birth_date: nil, chief_complaint: "c", relevant_history: "h"},
      frameworks: [], previous_sessions: [], current_notes: "n"}
  end

  setup do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)
  end

  test "usa o primeiro provider que responde :ok" do
    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad, :good],
      providers: %{
        bad: %{client: Stub, behavior: :error, model: "bad"},
        good: %{client: Stub, behavior: :ok, content: "SOAP OK", model: "good"}
      }
    )

    assert {:ok, %{content: "SOAP OK", provider: :good, model: "good"}} = AI.generate_soap(input())
  end

  test "todos falham → {:error, {:all_providers_failed, _}}" do
    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad], providers: %{bad: %{client: Stub, behavior: :error, model: "bad"}})

    assert {:error, {:all_providers_failed, _}} = AI.generate_soap(input())
  end
end
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement**

```elixir
# lib/ravanshenasi/ai.ex
defmodule Ravanshenasi.AI do
  @moduledoc "Domain facade: builds SOAP messages and tries providers in order (fallback)."

  alias Ravanshenasi.AI.Prompts

  @spec generate_soap(map()) ::
          {:ok, %{content: String.t(), provider: atom(), model: String.t()}}
          | {:error, {:all_providers_failed, list()}}
  def generate_soap(input) do
    messages = Prompts.soap_messages(input)
    cfg = Application.fetch_env!(:ravanshenasi, __MODULE__)
    try_providers(cfg[:order], cfg[:providers], messages, [])
  end

  defp try_providers([], _providers, _messages, errors),
    do: {:error, {:all_providers_failed, Enum.reverse(errors)}}

  defp try_providers([name | rest], providers, messages, errors) do
    case Map.get(providers, name) do
      nil ->
        try_providers(rest, providers, messages, [{name, :unknown_provider} | errors])

      pcfg ->
        if configured?(pcfg) do
          case pcfg.client.chat(pcfg, messages, []) do
            {:ok, content} when is_binary(content) and content != "" ->
              {:ok, %{content: content, provider: name, model: pcfg[:model]}}

            other ->
              try_providers(rest, providers, messages, [{name, other} | errors])
          end
        else
          try_providers(rest, providers, messages, [{name, :missing_config} | errors])
        end
    end
  end

  # Stub não precisa de credenciais; clientes HTTP precisam de base_url + api_key + model.
  defp configured?(%{client: Ravanshenasi.AI.Client.Stub}), do: true
  defp configured?(%{base_url: b, api_key: k, model: m}), do: present?(b) and present?(k) and present?(m)
  defp configured?(_), do: false
  defp present?(v), do: v not in [nil, ""]
end
```

- [ ] **Step 4: Run — PASS** (2).

---

## Task 7: `AI.Client.OpenAI` (impl protocolo OpenAI via req)

**Files:**
- Create: `lib/ravanshenasi/ai/client/open_ai.ex`
- Test: `test/ravanshenasi/ai/client/open_ai_test.exs`

- [ ] **Step 1: Failing test (Req.Test, sem rede)**

```elixir
# test/ravanshenasi/ai/client/open_ai_test.exs
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
end
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement**

```elixir
# lib/ravanshenasi/ai/client/open_ai.ex
defmodule Ravanshenasi.AI.Client.OpenAI do
  @moduledoc "OpenAI-protocol chat client (OpenAI, NVIDIA NIM, any compatible endpoint)."
  @behaviour Ravanshenasi.AI.Client

  @impl true
  def chat(cfg, messages, _opts) do
    req =
      Req.new(
        base_url: cfg.base_url,
        auth: {:bearer, cfg.api_key},
        receive_timeout: 60_000,
        # Req.Test plug intercepts in test env; no-op in prod.
        plug: Application.get_env(:ravanshenasi, :ai_req_plug)
      )

    body = %{model: cfg.model, messages: messages, temperature: 0.3}

    case Req.post(req, url: "/chat/completions", json: body) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}}
      when is_binary(content) and content != "" ->
        {:ok, content}

      {:ok, %{status: 200} = resp} ->
        # 200 mas content vazio / shape inesperado → erro (o facade tenta o próximo provider)
        {:error, {:empty_content, resp.body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```
> Em `config/test.exs` adicione `config :ravanshenasi, :ai_req_plug, {Req.Test, Ravanshenasi.AI.Client.OpenAI}`. Em prod o plug é `nil` (req faz a request real). Confirme a API do `Req.Test` na sua versão do `req` (`Req.Test.stub/2` + `plug: {Req.Test, name}`).

- [ ] **Step 4: Run — PASS** (2).

---

## Task 8: `Sessions` context — CRUD scoped + `recent_finalized`

**Files:**
- Create: `lib/ravanshenasi/sessions.ex`
- Test: `test/ravanshenasi/sessions_test.exs`

- [ ] **Step 1: Failing test**

```elixir
# test/ravanshenasi/sessions_test.exs
defmodule Ravanshenasi.SessionsTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.{Patients, Sessions}

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    %{scope: scope, patient: patient}
  end

  test "create + list scoped", %{scope: s, patient: p} do
    assert {:ok, sess} = Sessions.create_session(s, p, %{notes: "n1"})
    assert sess.status == :draft and sess.user_id == s.user.id and sess.patient_id == p.id
    assert [%{notes: "n1"}] = Sessions.list_sessions(s, p)
  end

  test "update bloqueado quando finalized", %{scope: s, patient: p} do
    {:ok, sess} = Sessions.create_session(s, p, %{notes: "n"})
    {:ok, _} = Ravanshenasi.Repo.transact_tenant(s, fn ->
      Ravanshenasi.Repo.update_all(
        from(x in Sessions.Session, where: x.id == ^sess.id), set: [status: :finalized])
      {:ok, :done}
    end)
    sess = Sessions.get_session!(s, sess.id)
    assert {:error, :finalized} = Sessions.update_session(s, sess, %{notes: "novo"})
  end

  test "outro profissional do mesmo tenant não vê", %{patient: _p} do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})
    {:ok, _} = Sessions.create_session(a, pa, %{notes: "secreto"})
    assert Sessions.list_sessions(b, pa) == []
  end

  test "admin de clínica não cria sessão", %{} do
    admin = clinic_admin_scope_fixture()
    {:ok, p} = Ravanshenasi.Repo.with_auth_bypass(fn -> {:ok, %Ravanshenasi.Patients.Patient{id: Ecto.UUID.generate()}} end)
    assert {:error, :unauthorized} = Sessions.create_session(admin, p, %{notes: "x"})
  end

  test "recent_finalized exclui a sessão informada", %{scope: s, patient: p} do
    {:ok, s1} = Sessions.create_session(s, p, %{notes: "antiga", date: ~U[2026-05-01 10:00:00Z]})
    {:ok, s2} = Sessions.create_session(s, p, %{notes: "atual", date: ~U[2026-06-01 10:00:00Z]})
    finalize!(s, s1)
    finalize!(s, s2)
    names = Sessions.recent_finalized(s, p, s2.id) |> Enum.map(& &1.notes)
    assert "antiga" in names
    refute "atual" in names
  end

  defp finalize!(scope, sess) do
    Ravanshenasi.Repo.transact_tenant(scope, fn ->
      Ravanshenasi.Repo.update_all(
        from(x in Ravanshenasi.Sessions.Session, where: x.id == ^sess.id), set: [status: :finalized])
    end)
  end
end
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement**

```elixir
# lib/ravanshenasi/sessions.ex
defmodule Ravanshenasi.Sessions do
  @moduledoc "Therapy sessions, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Repo
  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Patients.Patient
  alias Ravanshenasi.Sessions.Session

  def list_sessions(%Scope{} = scope, %Patient{} = patient) do
    transact_tenant(scope, fn ->
      Session |> scoped(scope) |> where([s], s.patient_id == ^patient.id)
      |> order_by([s], desc: s.date) |> Repo.all()
    end)
  end

  def get_session(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> Session |> scoped(scope) |> Repo.get(id) end)

  def get_session!(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> Session |> scoped(scope) |> Repo.get!(id) end)

  @doc "Sessão por id garantindo que pertence ao paciente da rota (além do scope)."
  def get_session_for_patient(%Scope{} = scope, %{id: patient_id}, id) do
    transact_tenant(scope, fn ->
      Session |> scoped(scope) |> where([s], s.patient_id == ^patient_id) |> Repo.get(id)
    end)
  end

  # Recebe %{id: ...} (duck-typed). NÃO confia no struct: recarrega o paciente por query
  # escopada (tenant_id + user_id) antes de criar a sessão.
  def create_session(%Scope{} = scope, %{id: patient_id}, attrs) do
    if Scope.clinical_access?(scope) do
      transact_tenant(scope, fn ->
        case Patient |> patient_scoped(scope) |> Repo.get(patient_id) do
          nil ->
            {:error, :unauthorized}

          patient ->
            %Session{tenant_id: scope.tenant.id, user_id: scope.user.id, patient_id: patient.id, status: :draft}
            |> Session.changeset(attrs)
            |> Repo.insert()
        end
      end)
    else
      {:error, :unauthorized}
    end
  end

  # NÃO confia no struct: recarrega a sessão por query escopada (tenant_id + user_id) usando
  # só o id; um struct stale/forjado com id de outra sessão do mesmo tenant não passa.
  def update_session(%Scope{} = scope, %{id: id}, attrs) do
    transact_tenant(scope, fn ->
      case Session |> scoped(scope) |> Repo.get(id) do
        nil -> {:error, :unauthorized}
        %Session{status: :finalized} -> {:error, :finalized}
        session -> session |> Session.changeset(attrs) |> Repo.update()
      end
    end)
  end

  defp patient_scoped(query, scope),
    do: from(p in query, where: p.tenant_id == ^scope.tenant.id and p.user_id == ^scope.user.id)

  def change_session(%Session{} = session, attrs \\ %{}), do: Session.changeset(session, attrs)

  @doc "Últimas `limit` sessões finalizadas do paciente, EXCLUINDO `exclude_session_id`."
  def recent_finalized(%Scope{} = scope, %Patient{} = patient, exclude_session_id, limit \\ 3) do
    transact_tenant(scope, fn ->
      Session
      |> scoped(scope)
      |> where([s], s.patient_id == ^patient.id and s.status == :finalized and s.id != ^exclude_session_id)
      |> order_by([s], desc: s.date)
      |> limit(^limit)
      |> Repo.all()
    end)
  end

  defp scoped(query, scope),
    do: from(s in query, where: s.tenant_id == ^scope.tenant.id and s.user_id == ^scope.user.id)

  defdelegate transact_tenant(scope, fun), to: Repo
end
```
> O teste "admin não cria" passa um `%Patient{}` sintético; `create_session` rejeita por `clinical_access?` antes de tocar o banco. Ajuste o teste se preferir um paciente real de outro therapist.

- [ ] **Step 4: Run — PASS**.

---

## Task 9: `Records` context

**Files:**
- Create: `lib/ravanshenasi/records.ex`
- Test: `test/ravanshenasi/records_test.exs`

- [ ] **Step 1: Failing test**

```elixir
# test/ravanshenasi/records_test.exs
defmodule Ravanshenasi.RecordsTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Patients, Sessions, Records}

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    {:ok, session} = Sessions.create_session(scope, patient, %{notes: "n"})
    {:ok, record} = insert_record(scope, session, patient)
    %{scope: scope, record: record}
  end

  test "mark_generating → complete grava content+model+done e faz broadcast", %{scope: s, record: r} do
    Records.subscribe(r.id)
    {:ok, r} = Records.mark_generating(s, r)
    assert r.generation_status == :generating
    {:ok, r} = Records.complete(s, r, "S:..\nO:..\nA:..\nP:..", "stub:stub-model")
    assert r.generation_status == :done and r.model_used == "stub:stub-model"
    assert_receive {:record_updated, %{generation_status: :done}}
  end

  test "retry_generation só de :error", %{scope: s, record: r} do
    {:ok, r} = Records.fail(s, r, "boom")
    assert r.generation_status == :error
    assert {:ok, r} = Records.retry_generation(s, r)
    assert r.generation_status == :pending
  end

  test "retry_generation em :done → {:error, :not_retryable}", %{scope: s, record: r} do
    {:ok, r} = Records.complete(s, r, "c", "m")
    assert {:error, :not_retryable} = Records.retry_generation(s, r)
  end

  defp insert_record(scope, session, patient) do
    Ravanshenasi.Repo.transact_tenant(scope, fn ->
      %Ravanshenasi.Records.Record{
        tenant_id: scope.tenant.id, user_id: scope.user.id,
        session_id: session.id, patient_id: patient.id, generation_status: :pending
      } |> Ecto.Changeset.change() |> Ravanshenasi.Repo.insert()
    end)
  end
end
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement**

```elixir
# lib/ravanshenasi/records.ex
defmodule Ravanshenasi.Records do
  @moduledoc "SOAP records, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Repo
  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Records.Record
  alias Ravanshenasi.Records.GenerateSoapWorker

  @pubsub Ravanshenasi.PubSub

  def get_record(%Scope{} = scope, id),
    do: transact_tenant(scope, fn -> Record |> scoped(scope) |> Repo.get(id) end)

  @doc "Record da sessão (duck-typed por id pra não acoplar Records→Sessions)."
  def get_record_for_session(%Scope{} = scope, %{id: session_id}),
    do: transact_tenant(scope, fn -> Record |> scoped(scope) |> Repo.get_by(session_id: session_id) end)

  @doc "Edita o conteúdo (só quando :done). NÃO confia no struct — recarrega escopado por id."
  def update_record(%Scope{} = scope, %{id: id}, attrs) do
    with_owned(scope, id, fn
      %Record{generation_status: :done} = r -> r |> Record.content_changeset(attrs) |> Repo.update()
      %Record{} -> {:error, :not_editable}
    end)
  end

  def mark_reviewed(%Scope{} = scope, %{id: id}) do
    with_owned(scope, id, fn r -> r |> Record.content_changeset(%{content: r.content, reviewed: true}) |> Repo.update() end)
  end

  def retry_generation(%Scope{} = scope, %{id: id}) do
    with_owned(scope, id, fn
      %Record{generation_status: :error} = r ->
        r
        |> Record.status_changeset(%{generation_status: :pending, error_reason: nil})
        |> Repo.update!()
        |> tap(fn rec -> Oban.insert!(GenerateSoapWorker.new(job_args(rec))) end)
        |> then(&{:ok, &1})

      %Record{} ->
        {:error, :not_retryable}
    end)
  end

  # --- internas (worker, scope reconstruído) — também recarregam, não confiam no struct ---
  def mark_generating(%Scope{} = scope, %{id: id}), do: set_status(scope, id, %{generation_status: :generating})

  def complete(%Scope{} = scope, %{id: id}, content, model_used),
    do: set_status(scope, id, %{generation_status: :done, content: content, model_used: model_used})

  def fail(%Scope{} = scope, %{id: id}, reason),
    do: set_status(scope, id, %{generation_status: :error, error_reason: inspect(reason)})

  defp set_status(scope, id, changes) do
    res = with_owned(scope, id, fn r -> r |> Record.status_changeset(changes) |> Repo.update() end)
    with {:ok, r} <- res, do: broadcast(r)
    res
  end

  # Recarrega o record por query escopada (tenant_id + user_id) e chama `fun`. Nunca opera
  # no struct do caller (que pode ser stale/forjado de outro profissional do mesmo tenant).
  defp with_owned(scope, id, fun) do
    transact_tenant(scope, fn ->
      case Record |> scoped(scope) |> Repo.get(id) do
        nil -> {:error, :unauthorized}
        record -> fun.(record)
      end
    end)
  end

  # --- pubsub ---
  def subscribe(record_id), do: Phoenix.PubSub.subscribe(@pubsub, "record:#{record_id}")
  def broadcast(%Record{} = r), do: Phoenix.PubSub.broadcast(@pubsub, "record:#{r.id}", {:record_updated, r})

  def job_args(%Record{} = r), do: %{record_id: r.id, user_id: r.user_id, tenant_id: r.tenant_id}

  defp scoped(query, scope),
    do: from(r in query, where: r.tenant_id == ^scope.tenant.id and r.user_id == ^scope.user.id)

  defdelegate transact_tenant(scope, fun), to: Repo
end
```

- [ ] **Step 4: Run — PASS**.

> `GenerateSoapWorker` ainda não existe — Task 10 cria. Se o compile reclamar em `retry_generation`, faça a Task 10 logo em seguida (ou crie um stub vazio do worker antes). Para manter TDD verde aqui, é aceitável criar o módulo `GenerateSoapWorker` mínimo (só `use Oban.Worker` + `perform/1` retornando `:ok`) na Task 10 antes de rodar a suíte completa.

---

## Task 10: `GenerateSoapWorker` (Oban.Worker)

**Files:**
- Create: `lib/ravanshenasi/records/generate_soap_worker.ex`
- Test: `test/ravanshenasi/records/generate_soap_worker_test.exs`

- [ ] **Step 1: Failing test (perform_job com stub IA)**

```elixir
# test/ravanshenasi/records/generate_soap_worker_test.exs
defmodule Ravanshenasi.Records.GenerateSoapWorkerTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Patients, Sessions, Records}
  alias Ravanshenasi.Records.{Record, GenerateSoapWorker}

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria", birth_date: ~D[1990-01-01]})
    {:ok, session} = Sessions.create_session(scope, patient, %{notes: "notas de hoje"})
    {:ok, record} =
      Ravanshenasi.Repo.transact_tenant(scope, fn ->
        %Record{tenant_id: scope.tenant.id, user_id: scope.user.id, session_id: session.id,
                patient_id: patient.id, generation_status: :pending}
        |> Ecto.Changeset.change() |> Ravanshenasi.Repo.insert()
      end)
    %{scope: scope, record: record}
  end

  test "sucesso → record done + content + model_used", %{scope: s, record: r} do
    assert :ok = perform_job(GenerateSoapWorker, Records.job_args(r))
    done = Records.get_record(s, r.id)
    assert done.generation_status == :done
    assert is_binary(done.content) and done.content != ""
    assert done.model_used == "stub:stub-model"
  end

  test "erro no último attempt → record error", %{scope: s, record: r} do
    prev = Application.get_env(:ravanshenasi, Ravanshenasi.AI)
    on_exit(fn -> Application.put_env(:ravanshenasi, Ravanshenasi.AI, prev) end)
    Application.put_env(:ravanshenasi, Ravanshenasi.AI,
      order: [:bad], providers: %{bad: %{client: Ravanshenasi.AI.Client.Stub, behavior: :error, model: "bad"}})

    # último attempt
    assert :ok = perform_job(GenerateSoapWorker, Records.job_args(r), attempt: 3)
    assert Records.get_record(s, r.id).generation_status == :error
  end
end
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement**

```elixir
# lib/ravanshenasi/records/generate_soap_worker.ex
defmodule Ravanshenasi.Records.GenerateSoapWorker do
  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Ravanshenasi.{AI, Patients, Sessions, Records}
  alias Ravanshenasi.Accounts.{Scope, User, Tenant}
  alias Ravanshenasi.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max}) do
    %{"record_id" => rid, "user_id" => uid, "tenant_id" => tid} = args

    with {:ok, scope} <- build_scope(uid, tid),
         %Records.Record{} = record <- Records.get_record(scope, rid) do
      {:ok, _} = Records.mark_generating(scope, record)
      input = build_input(scope, record)

      case AI.generate_soap(input) do
        {:ok, %{content: content, provider: provider, model: model}} ->
          {:ok, _} = Records.complete(scope, record, content, "#{provider}:#{model}")
          :ok

        {:error, reason} when attempt >= max ->
          {:ok, _} = Records.fail(scope, record, reason)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:discard, :not_found}
      {:error, :not_found} -> {:discard, :not_found}
    end
  end

  defp build_scope(uid, tid) do
    Repo.with_auth_bypass(fn ->
      # `%User{tenant_id: ^tid}` casa só se o user PERTENCE ao tenant do job — evita montar
      # um scope com user de um tenant e tenant de outro.
      with %User{tenant_id: ^tid} = user <- Repo.get(User, uid),
           %Tenant{} = tenant <- Repo.get(Tenant, tid) do
        {:ok, Scope.for_user(user) |> Scope.put_tenant(tenant)}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  defp build_input(scope, record) do
    patient = Patients.get_patient!(scope, record.patient_id)
    session = Sessions.get_session!(scope, record.session_id)

    %{
      patient: patient,
      frameworks: Patients.list_patient_frameworks(scope, patient),
      previous_sessions: Sessions.recent_finalized(scope, patient, session.id),
      current_notes: session.notes
    }
  end
end
```

- [ ] **Step 4: Run — PASS**. Depois `mix test` completo (Records + Sessions + AI verdes).

---

## Task 11: `Sessions.finalize_session` (UPDATE condicional + record + job)

**Files:**
- Modify: `lib/ravanshenasi/sessions.ex`
- Test: `test/ravanshenasi/sessions_finalize_test.exs`

- [ ] **Step 1: Failing test**

```elixir
# test/ravanshenasi/sessions_finalize_test.exs
defmodule Ravanshenasi.SessionsFinalizeTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Patients, Sessions, Records}
  alias Ravanshenasi.Records.GenerateSoapWorker

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    {:ok, session} = Sessions.create_session(scope, patient, %{notes: "n"})
    %{scope: scope, session: session}
  end

  test "finaliza + cria record pending + enfileira job", %{scope: s, session: sess} do
    assert {:ok, %{session: fsess, record: rec}} = Sessions.finalize_session(s, sess)
    assert fsess.status == :finalized
    assert rec.generation_status == :pending
    assert_enqueued worker: GenerateSoapWorker, args: %{record_id: rec.id}
  end

  test "finalizar 2x → {:error, :already_finalized} sem segundo job", %{scope: s, session: sess} do
    {:ok, _} = Sessions.finalize_session(s, sess)
    again = Sessions.get_session!(s, sess.id)
    assert {:error, :already_finalized} = Sessions.finalize_session(s, again)
    assert [_one] = all_enqueued(worker: GenerateSoapWorker)
  end
end
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement** — adicione a `lib/ravanshenasi/sessions.ex` (aliases `Record`, `GenerateSoapWorker`):

```elixir
  alias Ravanshenasi.Records.Record
  alias Ravanshenasi.Records.GenerateSoapWorker

  @doc "Finaliza a sessão (draft→finalized), cria o record pending e enfileira o job. Atômico."
  def finalize_session(%Scope{} = scope, %{id: id}) do
    if Scope.clinical_access?(scope), do: do_finalize(scope, id), else: {:error, :unauthorized}
  end

  # Repo.transaction PRÓPRIO (não transact_tenant, que LEVANTA em rollback). O UPDATE
  # condicional com RETURNING (`select: s`) faz três coisas: (1) serializa finalizações
  # concorrentes — só quem vê `status=:draft` vence; (2) o WHERE inclui user_id, então uma
  # sessão de OUTRO profissional do mesmo tenant não é tocada (perde a corrida → 0 linhas);
  # (3) devolve a LINHA DO BANCO, de onde derivamos tenant/user/patient do record (nunca do
  # struct do caller). Reseta o GUC no sucesso (como o transact_tenant) pra não vazar no
  # Sandbox; no rollback o Postgres reverte o SET LOCAL automaticamente.
  defp do_finalize(scope, id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT set_config('app.current_tenant_id', $1, true)", [scope.tenant.id])
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {_count, rows} =
        Repo.update_all(
          from(s in Session,
            where: s.id == ^id and s.tenant_id == ^scope.tenant.id and
                     s.user_id == ^scope.user.id and s.status == :draft,
            select: s),
          set: [status: :finalized, updated_at: now]
        )

      case rows do
        [] ->
          Repo.rollback(:already_finalized)

        [session] ->
          record =
            %Record{
              tenant_id: session.tenant_id, user_id: session.user_id,
              session_id: session.id, patient_id: session.patient_id, generation_status: :pending
            }
            |> Ecto.Changeset.change()
            |> Repo.insert!()

          Oban.insert!(GenerateSoapWorker.new(Records.job_args(record)))
          Repo.query!("SELECT set_config('app.current_tenant_id', '', true)")
          %{session: session, record: record}
      end
    end)
  end
```
> `Repo.transaction/1` retorna `{:ok, %{session, record}}` no sucesso e `{:error, :already_finalized}` no rollback — devolvido direto, sem o `unwrap` que levanta. Como o `WHERE` já garante owner+draft atomicamente, `finalize_session` só checa `clinical_access?` e dispensa `owns?` (que confiava no `status` possivelmente stale do struct). O `owns?/2` foi **removido** do módulo (não há mais uso — `update_session` recarrega por query escopada).

- [ ] **Step 4: Run — PASS** + `mix test` completo.

---

## Task 12: LiveViews de sessão + prontuário (PubSub)

**Files:**
- Create: `lib/ravanshenasi_web/live/session_live/{index,show,form}.ex`
- Modify: `lib/ravanshenasi_web/router.ex`
- Test: `test/ravanshenasi_web/live/session_live_test.exs`

- [ ] **Step 1: Inspecionar** os LiveViews de paciente (Fatia 1) e o `live_session :require_clinical` no router; siga o mesmo `Layouts.app`/componentes/`on_mount`.

- [ ] **Step 2: Failing test**

```elixir
# test/ravanshenasi_web/live/session_live_test.exs
defmodule RavanshenasiWeb.SessionLiveTest do
  use RavanshenasiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Patients, Sessions, Records}

  setup %{conn: conn} do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    %{conn: log_in_user(conn, scope.user), scope: scope, patient: patient}
  end

  test "cria sessão e finaliza mostra 'gerando'", %{conn: conn, scope: s, patient: p} do
    {:ok, sess} = Sessions.create_session(s, p, %{notes: "n"})
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/sessoes/#{sess.id}")
    html = lv |> element("button", "Finalizar") |> render_click()
    assert html =~ "Gerando" or html =~ "gerando"
  end

  test "broadcast done atualiza a tela", %{conn: conn, scope: s, patient: p} do
    {:ok, sess} = Sessions.create_session(s, p, %{notes: "n"})
    {:ok, %{record: rec}} = Sessions.finalize_session(s, sess)
    {:ok, lv, _} = live(conn, ~p"/pacientes/#{p.id}/sessoes/#{sess.id}")
    {:ok, _} = Records.complete(s, rec, "S: pronto\nO:..\nA:..\nP:..", "stub:stub-model")
    assert render(lv) =~ "pronto"
  end
end
```

- [ ] **Step 3: Rotas** — em `router.ex`, dentro da `live_session :require_clinical`:
```elixir
live "/pacientes/:patient_id/sessoes", SessionLive.Index, :index
live "/pacientes/:patient_id/sessoes/nova", SessionLive.Form, :new
live "/pacientes/:patient_id/sessoes/:id", SessionLive.Show, :show
```

- [ ] **Step 4: `SessionLive.Show`** (núcleo: finalizar + prontuário + PubSub). Carrega paciente + sessão escopados; botão "Finalizar" → `Sessions.finalize_session`; assina `Records.subscribe(record.id)` quando há record; `handle_info({:record_updated, r}, ...)` re-renderiza. Estados do record: `pending`/`generating` → "Gerando…"; `done` → mostra `content` + form de revisão (`Records.update_record`) + `mark_reviewed`; `error` → mensagem + botão "Tentar de novo" (`Records.retry_generation`). Use `<Layouts.app>` e componentes da Fatia 1.

```elixir
# lib/ravanshenasi_web/live/session_live/show.ex  (esqueleto — completar render conforme componentes reais)
defmodule RavanshenasiWeb.SessionLive.Show do
  use RavanshenasiWeb, :live_view
  alias Ravanshenasi.{Patients, Sessions, Records}

  @impl true
  def mount(%{"patient_id" => pid, "id" => sid}, _session, socket) do
    scope = socket.assigns.current_scope
    patient = Patients.get_patient!(scope, pid)

    case Sessions.get_session_for_patient(scope, patient, sid) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Session not found"))
         |> push_navigate(to: ~p"/pacientes/#{pid}/sessoes")}

      session ->
        record = Records.get_record_for_session(scope, session)
        if connected?(socket) and record, do: Records.subscribe(record.id)
        {:ok, assign(socket, patient: patient, session: session, record: record)}
    end
  end

  @impl true
  def handle_event("finalize", _, socket) do
    case Sessions.finalize_session(socket.assigns.current_scope, socket.assigns.session) do
      {:ok, %{session: sess, record: rec}} ->
        if connected?(socket), do: Records.subscribe(rec.id)
        {:noreply, assign(socket, session: sess, record: rec)}
      {:error, :already_finalized} -> {:noreply, put_flash(socket, :error, gettext("Already finalized"))}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not finalize"))}
    end
  end

  def handle_event("retry", _, socket) do
    {:ok, rec} = Records.retry_generation(socket.assigns.current_scope, socket.assigns.record)
    {:noreply, assign(socket, record: rec)}
  end

  @impl true
  def handle_info({:record_updated, rec}, socket), do: {:noreply, assign(socket, record: rec)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>{gettext("Session")} — {@patient.name}</.header>
      <p>{@session.notes}</p>
      <.button :if={@session.status == :draft} phx-click="finalize">{gettext("Finalize")}</.button>

      <div :if={@record}>
        <p :if={@record.generation_status in [:pending, :generating]}>{gettext("Generating record...")}</p>
        <div :if={@record.generation_status == :done}>
          <h3>{gettext("SOAP record")}</h3>
          <pre>{@record.content}</pre>
        </div>
        <div :if={@record.generation_status == :error}>
          <p>{gettext("Generation failed")}: {@record.error_reason}</p>
          <.button phx-click="retry">{gettext("Try again")}</.button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
```
> `Records.get_record_for_session/2` já existe (T9). `SessionLive.Index` (lista sessões do paciente + link "nova") e `SessionLive.Form` (new: cria draft, edita notas) seguem o padrão do `PatientLive`. O teste "broadcast done" funciona porque a LiveView assina o tópico e o `Records.complete` faz broadcast.

- [ ] **Step 4: Run — PASS** + `mix test` completo. Ajuste seletores/labels conforme os componentes reais.

---

## Task 13: Fechamento — config runtime + precommit

**Files:**
- Modify: `config/runtime.exs` (providers via env)
- (sem código novo)

- [ ] **Step 1: Providers via env (runtime.exs)**

Em `config/runtime.exs`, no bloco `if config_env() == :prod do`, configure os providers a partir de env (NIM e/ou OpenAI), montando o registry de `Ravanshenasi.AI`:
```elixir
config :ravanshenasi, Ravanshenasi.AI,
  # Whitelist: nunca String.to_atom em input externo. Só nomes conhecidos viram átomos.
  order:
    System.get_env("AI_ORDER", "openai")
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn name ->
      case String.trim(name) do
        "openai" -> [:openai]
        "nim" -> [:nim]
        _ -> []
      end
    end),
  providers: %{
    openai: %{client: Ravanshenasi.AI.Client.OpenAI,
              base_url: System.get_env("OPENAI_BASE_URL", "https://api.openai.com/v1"),
              api_key: System.get_env("OPENAI_API_KEY"),
              model: System.get_env("OPENAI_MODEL", "gpt-4o-mini")},
    nim: %{client: Ravanshenasi.AI.Client.OpenAI,
           base_url: System.get_env("NIM_BASE_URL", "https://integrate.api.nvidia.com/v1"),
           api_key: System.get_env("NIM_API_KEY"),
           model: System.get_env("NIM_MODEL")}
  }
```
> Documente as envs no `.env.example`/README se existir.

- [ ] **Step 2: precommit**

Run: `mix precommit`
Expected: compile sem warnings, format ok, **credo --strict 0**, **todos os testes verdes**, e **nenhum teste bate na API real** (tudo via `Client.Stub`/`Req.Test`).

> Se o Credo apontar alias/nesting/moduledoc nos módulos novos, ajuste (não desabilite). **Não commitar** — deixe o working tree pronto para o usuário.

---

## Definition of Done (contra o spec)

- [ ] Oban (dep + `oban_jobs` + supervisor + queue `:ai`); testing `:manual`. *(T1)*
- [ ] `sessions` + `records` com FK composta + RLS; unique `(session_id)`; FKs record↔session `(session_id,tenant_id,user_id)` e `(session_id,patient_id)`. *(T2, T3)*
- [ ] Subsistema IA: behaviour + Stub + OpenAI-protocol (req/Req.Test); `AI.generate_soap` com fallback; prompt SOAP (perfil+frameworks+3 anteriores+notas). *(T4–T7)*
- [ ] Sessions CRUD scoped; `recent_finalized` exclui a atual; admin barrado. *(T8)*
- [ ] Records: mark/complete/fail/retry + PubSub broadcast/subscribe; `update_record` só `:done`. *(T9)*
- [ ] `GenerateSoapWorker`: carrega/valida record escopado; `done`/`error` (último attempt); IA fora de transação. *(T10)*
- [ ] `finalize_session` atômico via UPDATE condicional; record `pending` + job (`assert_enqueued`); idempotente. *(T11)*
- [ ] LiveView: finalizar → "gerando"; broadcast `done`/`error` atualiza; revisão + retry. *(T12)*
- [ ] `mix precommit` verde; testes não batem na API real. *(T13)*

---

## Notas de risco para o executor

1. **`finalize_session` e o `unwrap_transaction` que levanta:** o `transact_tenant` da Fatia 0 levanta em `Repo.rollback`. Para `finalize` retornar `{:error, :already_finalized}` limpo, use `Repo.transaction/1` próprio com `set_config` do GUC (ver nota na Task 11), **não** `transact_tenant`.
2. **`Req.Test`:** confirme a API na versão do `req` (`plug: {Req.Test, name}` + `Req.Test.stub/2`). O `Client.OpenAI` lê o plug de `:ai_req_plug` (nil em prod).
3. **Oban testing:** `testing: :manual` + `use Oban.Testing` no DataCase → `assert_enqueued`/`perform_job`/`all_enqueued`. Jobs não rodam sozinhos no teste.
4. **`async: false`** em todo teste que toca `transact_tenant`/bypass/PubSub-no-corpo.
5. **Migração das FKs compostas** via `execute/2` (SQL cru) — confirme que `sessions` tem os unique `(id,tenant_id,user_id)` e `(id,patient_id)` ANTES (Task 2) ou a constraint falha.
6. **RLS + Oban:** `oban_jobs` não tem RLS; `Oban.insert!` dentro do `transact_tenant`/transação com GUC setado funciona normalmente.
