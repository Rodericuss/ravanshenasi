# Fatia 1 — Pacientes + Linhas de Pensamento Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar o núcleo clínico sobre a Fundação — CRUD de pacientes scoped por profissional e linhas de pensamento (catálogo do tenant herdado + próprias), com RLS em todo dado clínico e autorização imposta no context.

**Architecture:** Dois contexts novos (`Patients`, `Frameworks`). Toda leitura/escrita clínica roda em `Repo.transact_tenant(scope, …)`; as tabelas têm RLS fail-closed por `tenant_id` (`Ravanshenasi.RLS.enable_tenant_rls/1`) **e** FKs compostas `(tenant_id, …)` pra integridade tenant-aware no banco. Autorização via `Scope.clinical_access?/1` (therapist ou solo-admin) e `Scope.admin?/1` (catálogo do tenant). Seed das 7 predefinidas no `do_register` (solo+clínica) via o `Ecto.Multi` existente.

**Tech Stack:** Elixir 1.19 · Phoenix 1.8.7 · LiveView 1.1 · Ecto/Postgrex · TimescaleDB HA pg17.

**Spec:** `docs/superpowers/specs/2026-06-03-fatia-1-pacientes-linhas-pensamento-design.md`

---

## Convenções (lidas do código da Fatia 0)

- **Binary IDs** em tudo (`:binary_id`). Enums via `Ecto.Enum` + coluna `:string`.
- `Repo.transact_tenant(scope, fn -> … end)` → resultado **cru**; levanta sem tenant; reseta o GUC no fim.
- `Repo.with_registration_bypass_multi(%Ecto.Multi{})` → `{:ok, map}` | `{:error, step, changeset, changes}`; injeta o `SET LOCAL` como passos (não aninha transação).
- `Ravanshenasi.RLS.enable_tenant_rls(table, column \\ "tenant_id")` — policy fail-closed com `NULLIF`.
- Fixtures: `user_scope_fixture/0` → `%Scope{user, tenant}` pronto; `user_scope_fixture/1` idem a partir de um user.
- **Testes que exercitam `transact_tenant`/bypass no corpo:** `use Ravanshenasi.DataCase, async: false` (race do `SET LOCAL` sob o Sandbox — ver Adendo da Fatia 0). Testes de schema/changeset puros podem ser `async: true`.
- `mix test caminho:linha`. Rodar `mix test` antes de cada commit.
- **Não commitar** automaticamente se o usuário pediu pra commitar ele mesmo; este plano mostra o commit sugerido por task no padrão do repo (gitmoji + conventional, inglês, one-line, sem trailer).

---

## File Structure

**Criados:**
- `lib/ravanshenasi/frameworks.ex` — context de linhas de pensamento.
- `lib/ravanshenasi/frameworks/thinking_framework.ex` — schema.
- `lib/ravanshenasi/frameworks/defaults.ex` — as 7 predefinidas (dados).
- `lib/ravanshenasi/patients.ex` — context de pacientes + associação.
- `lib/ravanshenasi/patients/patient.ex` — schema.
- `lib/ravanshenasi/patients/patient_framework.ex` — join schema.
- `lib/ravanshenasi_web/live/framework_live/index.ex`
- `lib/ravanshenasi_web/live/patient_live/{index,show,form}.ex`
- migrations (ver tasks).

**Estendidos:**
- `lib/ravanshenasi/accounts/scope.ex` — `+clinical_access?/1`.
- `lib/ravanshenasi/accounts.ex` — `do_register/2` encadeia o seed.
- `lib/ravanshenasi_web/router.ex` — rotas + nav por papel.
- `docs/FEATURES.md`, `docs/DATA_MODEL.md` — encolher (seções absorvidas).

---

## Task 1: `Scope.clinical_access?/1`

Quem **atende** (acessa dado clínico): therapist, ou admin de tenant solo. Admin de clínica não.

**Files:**
- Modify: `lib/ravanshenasi/accounts/scope.ex`
- Test: `test/ravanshenasi/accounts/scope_clinical_access_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi/accounts/scope_clinical_access_test.exs
defmodule Ravanshenasi.Accounts.ScopeClinicalAccessTest do
  use ExUnit.Case, async: true

  alias Ravanshenasi.Accounts.{Scope, Tenant, User}

  defp scope(role, plan) do
    %Scope{user: %User{role: role}, tenant: %Tenant{plan: plan}}
  end

  test "therapist tem acesso clínico em qualquer plano" do
    assert Scope.clinical_access?(scope(:therapist, :clinic))
    assert Scope.clinical_access?(scope(:therapist, :solo))
  end

  test "solo-admin tem acesso clínico; admin de clínica não" do
    assert Scope.clinical_access?(scope(:admin, :solo))
    refute Scope.clinical_access?(scope(:admin, :clinic))
  end

  test "scope sem user não tem acesso" do
    refute Scope.clinical_access?(%Scope{user: nil, tenant: nil})
  end
end
```

- [ ] **Step 2: Rodar — falha**

Run: `mix test test/ravanshenasi/accounts/scope_clinical_access_test.exs`
Expected: FAIL — `clinical_access?/1` indefinido.

- [ ] **Step 3: Implementar**

Adicione em `lib/ravanshenasi/accounts/scope.ex` (depois de `therapist?/1`):

```elixir
@doc """
True if the scope's user provides clinical care (sees patients):
a therapist, or the admin of a solo tenant. A clinic admin does not.
"""
def clinical_access?(%__MODULE__{user: %{role: :therapist}}), do: true
def clinical_access?(%__MODULE__{user: %{role: :admin}, tenant: %{plan: :solo}}), do: true
def clinical_access?(_), do: false
```

- [ ] **Step 4: Rodar — passa**

Run: `mix test test/ravanshenasi/accounts/scope_clinical_access_test.exs`
Expected: PASS (3 testes).

- [ ] **Step 5: Commit**

```
✨ feat(authz): Scope.clinical_access? distinguishes solo-admin from clinic-admin
```

---

## Task 2: Migration — unique `(id, tenant_id)` em `users`

Pré-requisito das FKs compostas tenant-aware das próximas tabelas (referenciam `users (id, tenant_id)`).

**Files:**
- Create: `priv/repo/migrations/<ts>_add_user_tenant_unique_index.exs`

- [ ] **Step 1: Criar a migration**

```elixir
# priv/repo/migrations/<ts>_add_user_tenant_unique_index.exs
defmodule Ravanshenasi.Repo.Migrations.AddUserTenantUniqueIndex do
  use Ecto.Migration

  # Composite-FK target: lets clinical tables reference users (id, tenant_id),
  # enforcing same-tenant ownership at the DB level.
  def change do
    create unique_index(:users, [:id, :tenant_id])
  end
end
```

- [ ] **Step 2: Migrar**

Run: `mix ecto.migrate`
Expected: índice criado, sem erro.

- [ ] **Step 3: Verificar o índice**

Run: `mix run -e "IO.inspect Ravanshenasi.Repo.query!(\"SELECT indexname FROM pg_indexes WHERE tablename='users' AND indexname LIKE '%id_tenant_id%'\").rows"`
Expected: lista com `users_id_tenant_id_index`.

> Sem teste unitário: índice estrutural sem comportamento próprio. O comportamento que ele habilita (FK composta) é testado na Task 6.

- [ ] **Step 4: Commit**

```
🔧 chore(db): unique (id, tenant_id) on users for composite FKs
```

---

## Task 3: Schema + migration de `thinking_frameworks`

**Files:**
- Create: `lib/ravanshenasi/frameworks/thinking_framework.ex`
- Create: `priv/repo/migrations/<ts>_create_thinking_frameworks.exs`
- Test: `test/ravanshenasi/frameworks/thinking_framework_test.exs`

- [ ] **Step 1: Teste do changeset (falha)**

```elixir
# test/ravanshenasi/frameworks/thinking_framework_test.exs
defmodule Ravanshenasi.Frameworks.ThinkingFrameworkTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Frameworks.ThinkingFramework

  test "changeset válido com name + description" do
    cs = ThinkingFramework.changeset(%ThinkingFramework{}, %{name: "TCC", description: "..."})
    assert cs.valid?
  end

  test "name é obrigatório" do
    cs = ThinkingFramework.changeset(%ThinkingFramework{}, %{description: "x"})
    refute cs.valid?
    assert %{name: ["can't be blank"]} = errors_on(cs)
  end
end
```

- [ ] **Step 2: Rodar — falha**

Run: `mix test test/ravanshenasi/frameworks/thinking_framework_test.exs`
Expected: FAIL — módulo indefinido.

- [ ] **Step 3: Migration**

```elixir
# priv/repo/migrations/<ts>_create_thinking_frameworks.exs
defmodule Ravanshenasi.Repo.Migrations.CreateThinkingFrameworks do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:thinking_frameworks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      # Composite FK: own frameworks belong to a user OF THE SAME TENANT.
      # user_id NULL = tenant catalog; MATCH SIMPLE skips the FK check when null.
      add :user_id,
          references(:users, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :delete_all)

      add :name, :string, null: false
      add :description, :text
      add :is_predefined, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:thinking_frameworks, [:tenant_id, :user_id])
    # Composite-FK target for patient_frameworks.
    create unique_index(:thinking_frameworks, [:id, :tenant_id])
    # No duplicate name within the catalog (user_id NULL) or within one user's own.
    create unique_index(:thinking_frameworks, [:tenant_id, :user_id, :name],
             nulls_distinct: false,
             name: :thinking_frameworks_tenant_user_name_index
           )

    enable_tenant_rls("thinking_frameworks")
  end
end
```

> `nulls_distinct: false` gera `NULLS NOT DISTINCT` (PG15+). Confirma que sua versão do Ecto suporta a opção; se não, use `execute/2` com SQL cru: `CREATE UNIQUE INDEX ... (tenant_id, user_id, name) NULLS NOT DISTINCT`.

- [ ] **Step 4: Schema**

```elixir
# lib/ravanshenasi/frameworks/thinking_framework.ex
defmodule Ravanshenasi.Frameworks.ThinkingFramework do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "thinking_frameworks" do
    field :name, :string
    field :description, :string
    field :is_predefined, :boolean, default: false

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "User-facing changeset (create/edit name + description)."
  def changeset(framework, attrs) do
    framework
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name, name: :thinking_frameworks_tenant_user_name_index)
  end
end
```

- [ ] **Step 5: Migrar + testar**

Run: `mix ecto.migrate && mix test test/ravanshenasi/frameworks/thinking_framework_test.exs`
Expected: PASS (2 testes).

- [ ] **Step 6: Commit**

```
✨ feat(frameworks): thinking_frameworks schema + migration with tenant RLS
```

---

## Task 4: `Frameworks` context — defaults, listagem, CRUD, autorização

**Files:**
- Create: `lib/ravanshenasi/frameworks/defaults.ex`
- Create: `lib/ravanshenasi/frameworks.ex`
- Test: `test/ravanshenasi/frameworks_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi/frameworks_test.exs
defmodule Ravanshenasi.FrameworksTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.Frameworks
  alias Ravanshenasi.Accounts.Scope

  test "default_frameworks devolve as 7 predefinidas" do
    names = Frameworks.default_frameworks() |> Enum.map(& &1.name)
    assert length(names) == 7
    assert "TCC" in names
  end

  test "admin cria framework de catálogo (user_id nil) e aparece na listagem" do
    scope = user_scope_fixture()
    assert {:ok, fw} = Frameworks.create_tenant_framework(scope, %{name: "Sistêmica", description: "..."})
    assert fw.user_id == nil
    assert "Sistêmica" in Enum.map(Frameworks.list_frameworks(scope), & &1.name)
  end

  test "therapist não cria framework de catálogo" do
    scope = therapist_scope_fixture()
    assert {:error, :unauthorized} = Frameworks.create_tenant_framework(scope, %{name: "X", description: "y"})
  end

  test "clinic-admin não cria framework próprio" do
    scope = clinic_admin_scope_fixture()
    assert {:error, :unauthorized} = Frameworks.create_own_framework(scope, %{name: "X", description: "y"})
  end

  test "list_frameworks faz união simples: catálogo do tenant + próprios do user, não de outro user" do
    admin = clinic_admin_scope_fixture()
    scope = therapist_scope_fixture(admin.tenant)
    other = therapist_scope_fixture(admin.tenant)

    {:ok, _own} = Frameworks.create_own_framework(scope, %{name: "Minha Linha", description: "..."})
    {:ok, _other_own} = Frameworks.create_own_framework(other, %{name: "Linha do Outro", description: "..."})

    names = Frameworks.list_frameworks(scope) |> Enum.map(& &1.name)
    assert "Minha Linha" in names       # própria
    assert "TCC" in names               # catálogo do tenant (herdado)
    refute "Linha do Outro" in names    # própria do colega — invisível
  end
end
```

> Este teste usa três fixtures de scope ainda inexistentes: `therapist_scope_fixture/0|1` e `clinic_admin_scope_fixture/0`. Crie-os no Step 3a antes de implementar o context.

- [ ] **Step 2: Rodar — falha**

Run: `mix test test/ravanshenasi/frameworks_test.exs`
Expected: FAIL — fixtures/context indefinidos.

- [ ] **Step 3a: Fixtures de scope por papel**

Adicione em `test/support/fixtures/accounts_fixtures.ex`:

```elixir
@doc """
Scope of a therapist invited into a CLINIC tenant. Invitations are clinic-only
(Fatia 0: require_clinic_admin), so a tenant is NOT optional in spirit — when nil,
a fresh clinic is created. Pass a clinic tenant to put two therapists in the same one.
"""
def therapist_scope_fixture(tenant \\ nil) do
  admin_scope =
    case tenant do
      nil -> clinic_admin_scope_fixture()
      t -> admin_scope_for(t)
    end

  email = "therapist#{System.unique_integer()}@example.com"
  {:ok, raw} = Ravanshenasi.Accounts.create_invitation(admin_scope, %{email: email, role: :therapist})
  {:ok, user} = Ravanshenasi.Accounts.accept_invitation(raw, %{name: "Therapist", password: "supersecret123"})
  user = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.preload(user, :tenant) end)
  Ravanshenasi.Accounts.Scope.for_user(user) |> Ravanshenasi.Accounts.Scope.put_tenant(user.tenant)
end

@doc "Scope of a clinic admin (plan: :clinic), who manages but does not attend."
def clinic_admin_scope_fixture do
  {:ok, user} = Ravanshenasi.Accounts.register_clinic(%{clinic_name: "Clinic", name: "Admin", email: "admin#{System.unique_integer()}@example.com"})
  user = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.preload(user, :tenant) end)
  Ravanshenasi.Accounts.Scope.for_user(user) |> Ravanshenasi.Accounts.Scope.put_tenant(user.tenant)
end

# helper privado: scope admin a partir de um tenant existente (pega o 1º admin)
defp admin_scope_for(tenant) do
  user = Ravanshenasi.Repo.with_auth_bypass(fn ->
    Ravanshenasi.Repo.one!(from u in Ravanshenasi.Accounts.User, where: u.tenant_id == ^tenant.id and u.role == :admin, limit: 1)
  end)
  Ravanshenasi.Accounts.Scope.for_user(user) |> Ravanshenasi.Accounts.Scope.put_tenant(tenant)
end
```

> Adicione `import Ecto.Query` ao topo do fixtures se faltar.

- [ ] **Step 3b: Defaults (as 7 linhas)**

```elixir
# lib/ravanshenasi/frameworks/defaults.ex
defmodule Ravanshenasi.Frameworks.Defaults do
  @moduledoc "The 7 predefined therapeutic lines seeded per tenant."

  @frameworks [
    %{name: "TCC", description: "Terapia Cognitivo-Comportamental: identifica e reestrutura pensamentos e crenças disfuncionais; foco no presente, psicoeducação e tarefas entre sessões."},
    %{name: "Psicanálise", description: "Explora o inconsciente, conflitos internos, transferência e história infantil; associação livre e interpretação."},
    %{name: "Psicologia Analítica", description: "Abordagem junguiana: self, arquétipos, inconsciente coletivo, processo de individuação, símbolos e sonhos."},
    %{name: "Gestalt-terapia", description: "Awareness no aqui-e-agora, contato, responsabilidade e experimentos vivenciais; foco no processo."},
    %{name: "ACT", description: "Terapia de Aceitação e Compromisso: aceitação, desfusão cognitiva, valores e ação comprometida; flexibilidade psicológica."},
    %{name: "DBT", description: "Terapia Comportamental Dialética: regulação emocional, tolerância ao mal-estar, mindfulness e efetividade interpessoal."},
    %{name: "Humanista", description: "Abordagem centrada na pessoa: empatia, aceitação positiva incondicional e congruência; confia na tendência atualizante."}
  ]

  def all, do: @frameworks
end
```

- [ ] **Step 3c: Context**

```elixir
# lib/ravanshenasi/frameworks.ex
defmodule Ravanshenasi.Frameworks do
  @moduledoc "Therapeutic lines of thought: tenant catalog + practitioner's own."

  import Ecto.Query

  alias Ravanshenasi.Repo
  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Frameworks.{Defaults, ThinkingFramework}

  @doc "The 7 predefined lines (name + description)."
  def default_frameworks, do: Defaults.all()

  @doc "Lines visible to the scope: tenant catalog (user_id NULL) ∪ own (user_id = self)."
  def list_frameworks(%Scope{} = scope) do
    uid = scope.user.id

    transact_tenant(scope, fn ->
      Repo.all(
        from f in ThinkingFramework,
          where: is_nil(f.user_id) or f.user_id == ^uid,
          order_by: [asc: f.name]
      )
    end)
  end

  def get_framework!(%Scope{} = scope, id) do
    uid = scope.user.id

    transact_tenant(scope, fn ->
      Repo.one!(
        from f in ThinkingFramework,
          where: f.id == ^id and (is_nil(f.user_id) or f.user_id == ^uid)
      )
    end)
  end

  @doc "Creates a tenant-catalog line (user_id NULL). Requires admin."
  def create_tenant_framework(%Scope{} = scope, attrs) do
    if Scope.admin?(scope) do
      insert_framework(scope, attrs, nil)
    else
      {:error, :unauthorized}
    end
  end

  @doc "Creates the practitioner's own line (user_id = self). Requires clinical access."
  def create_own_framework(%Scope{} = scope, attrs) do
    if Scope.clinical_access?(scope) do
      insert_framework(scope, attrs, scope.user.id)
    else
      {:error, :unauthorized}
    end
  end

  defp insert_framework(scope, attrs, user_id) do
    transact_tenant(scope, fn ->
      %ThinkingFramework{tenant_id: scope.tenant.id, user_id: user_id}
      |> ThinkingFramework.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @doc "Updates a line. Catalog lines require admin; own lines require clinical access."
  def update_framework(%Scope{} = scope, %ThinkingFramework{} = fw, attrs) do
    if can_manage?(scope, fw) do
      transact_tenant(scope, fn -> fw |> ThinkingFramework.changeset(attrs) |> Repo.update() end)
    else
      {:error, :unauthorized}
    end
  end

  @doc "Deletes a line (cascade removes patient associations)."
  def delete_framework(%Scope{} = scope, %ThinkingFramework{} = fw) do
    if can_manage?(scope, fw) do
      transact_tenant(scope, fn -> Repo.delete(fw) end)
    else
      {:error, :unauthorized}
    end
  end

  defp can_manage?(scope, %ThinkingFramework{user_id: nil}), do: Scope.admin?(scope)
  defp can_manage?(scope, %ThinkingFramework{user_id: uid}), do: scope.user.id == uid and Scope.clinical_access?(scope)

  # Inserts the 7 default lines at tenant level (user_id NULL). Runs inside the
  # registration Multi (bypass active). `repo` is the dynamic repo of the Multi.
  @doc false
  def seed_tenant_defaults(repo, tenant_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(Defaults.all(), fn attrs ->
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          user_id: nil,
          name: attrs.name,
          description: attrs.description,
          is_predefined: true,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo.insert_all(ThinkingFramework, rows)
    :ok
  end

  defdelegate transact_tenant(scope, fun), to: Repo
end
```

- [ ] **Step 4: Rodar — passa**

Run: `mix test test/ravanshenasi/frameworks_test.exs`
Expected: PASS (5 testes).

- [ ] **Step 5: Commit**

```
✨ feat(frameworks): context with catalog/own lines, union listing and authz
```

---

## Task 5: Seed no registro + backfill

**Files:**
- Modify: `lib/ravanshenasi/accounts.ex` (`do_register/2`)
- Create: `priv/repo/migrations/<ts>_seed_default_frameworks_backfill.exs`
- Test: `test/ravanshenasi/accounts/register_seed_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi/accounts/register_seed_test.exs
defmodule Ravanshenasi.Accounts.RegisterSeedTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.{Accounts, Frameworks}
  alias Ravanshenasi.Accounts.Scope

  defp scope_of(user) do
    user = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.preload(user, :tenant) end)
    Scope.for_user(user) |> Scope.put_tenant(user.tenant)
  end

  test "register_solo cria 7 frameworks de catálogo" do
    {:ok, user} = Accounts.register_solo(%{name: "A", email: "solo#{System.unique_integer()}@ex.com", office_name: "C"})
    assert length(Frameworks.list_frameworks(scope_of(user))) == 7
  end

  test "register_clinic cria 7 frameworks de catálogo" do
    {:ok, user} = Accounts.register_clinic(%{clinic_name: "C", name: "A", email: "cli#{System.unique_integer()}@ex.com"})
    assert length(Frameworks.list_frameworks(scope_of(user))) == 7
  end

  test "accept_invitation NÃO duplica catálogo (therapist herda)" do
    admin = clinic_admin_scope_fixture()
    {:ok, raw} = Accounts.create_invitation(admin, %{email: "m#{System.unique_integer()}@ex.com", role: :therapist})
    {:ok, member} = Accounts.accept_invitation(raw, %{name: "M", password: "supersecret123"})
    # vê os 7 do tenant, nenhum próprio
    assert length(Frameworks.list_frameworks(scope_of(member))) == 7
  end
end
```

- [ ] **Step 2: Rodar — falha**

Run: `mix test test/ravanshenasi/accounts/register_seed_test.exs`
Expected: FAIL — `register_solo` cria 0 frameworks.

- [ ] **Step 3: Encadear o seed no `do_register`**

Em `lib/ravanshenasi/accounts.ex`, no `defp do_register`, adicione um passo ao Multi após o `:user`:

```elixir
# alias no topo do módulo, se faltar:
# alias Ravanshenasi.Frameworks

defp do_register(tenant_attrs, user_attrs) do
  multi =
    Multi.new()
    |> Multi.insert(:tenant, Tenant.changeset(%Tenant{}, tenant_attrs))
    |> Multi.insert(:user, fn %{tenant: tenant} ->
      %User{}
      |> User.email_changeset(%{email: user_attrs.email})
      |> maybe_put_password(user_attrs[:password])
      |> User.tenant_changeset(%{tenant_id: tenant.id, name: user_attrs.name, role: user_attrs.role})
    end)
    |> Multi.run(:seed_frameworks, fn repo, %{tenant: tenant} ->
      Frameworks.seed_tenant_defaults(repo, tenant.id)
      {:ok, :seeded}
    end)

  case Repo.with_registration_bypass_multi(multi) do
    {:ok, %{user: user}} -> {:ok, user}
    {:error, _step, changeset, _} -> {:error, changeset}
  end
end
```

> O `Multi.run` roda dentro do `with_registration_bypass_multi`, então o `app.auth_bypass` está `on` — o insert nos `thinking_frameworks` (RLS) passa pelo `WITH CHECK`.

- [ ] **Step 4: Backfill (tenants existentes)**

```elixir
# priv/repo/migrations/<ts>_seed_default_frameworks_backfill.exs
defmodule Ravanshenasi.Repo.Migrations.SeedDefaultFrameworksBackfill do
  use Ecto.Migration

  # Frozen copy of the 7 defaults (a data migration must not depend on app code
  # that may change). Bypass is required: thinking_frameworks already has FORCE RLS.
  def up do
    execute("SET LOCAL app.auth_bypass = 'on'")

    execute("""
    INSERT INTO thinking_frameworks (id, tenant_id, user_id, name, description, is_predefined, inserted_at, updated_at)
    SELECT gen_random_uuid(), t.id, NULL, d.name, d.description, true, now(), now()
    FROM tenants t
    CROSS JOIN (VALUES
      ('TCC', 'Terapia Cognitivo-Comportamental: identifica e reestrutura pensamentos e crenças disfuncionais; foco no presente, psicoeducação e tarefas entre sessões.'),
      ('Psicanálise', 'Explora o inconsciente, conflitos internos, transferência e história infantil; associação livre e interpretação.'),
      ('Psicologia Analítica', 'Abordagem junguiana: self, arquétipos, inconsciente coletivo, processo de individuação, símbolos e sonhos.'),
      ('Gestalt-terapia', 'Awareness no aqui-e-agora, contato, responsabilidade e experimentos vivenciais; foco no processo.'),
      ('ACT', 'Terapia de Aceitação e Compromisso: aceitação, desfusão cognitiva, valores e ação comprometida; flexibilidade psicológica.'),
      ('DBT', 'Terapia Comportamental Dialética: regulação emocional, tolerância ao mal-estar, mindfulness e efetividade interpessoal.'),
      ('Humanista', 'Abordagem centrada na pessoa: empatia, aceitação positiva incondicional e congruência; confia na tendência atualizante.')
    ) AS d(name, description)
    WHERE NOT EXISTS (
      SELECT 1 FROM thinking_frameworks f WHERE f.tenant_id = t.id AND f.user_id IS NULL
    )
    """)
  end

  def down, do: :ok
end
```

- [ ] **Step 5: Rodar — passa**

Run: `mix ecto.migrate && mix test test/ravanshenasi/accounts/register_seed_test.exs`
Expected: PASS (3 testes). Rode também `mix test test/ravanshenasi/accounts` — os registros existentes da Fatia 0 continuam verdes (agora com seed).

- [ ] **Step 6: Commit**

```
✨ feat(frameworks): seed 7 defaults per tenant on registration + backfill
```

---

## Task 6: Schema + migration de `patients`

**Files:**
- Create: `lib/ravanshenasi/patients/patient.ex`
- Create: `priv/repo/migrations/<ts>_create_patients.exs`
- Test: `test/ravanshenasi/patients/patient_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi/patients/patient_test.exs
defmodule Ravanshenasi.Patients.PatientTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Patients.Patient

  test "changeset válido" do
    cs = Patient.changeset(%Patient{}, %{name: "Maria", status: :active})
    assert cs.valid?
  end

  test "name obrigatório" do
    cs = Patient.changeset(%Patient{}, %{status: :active})
    refute cs.valid?
    assert %{name: ["can't be blank"]} = errors_on(cs)
  end

  test "status fora do enum é inválido" do
    cs = Patient.changeset(%Patient{}, %{name: "X", status: :deleted})
    refute cs.valid?
  end
end
```

- [ ] **Step 2: Rodar — falha**

Run: `mix test test/ravanshenasi/patients/patient_test.exs`
Expected: FAIL — módulo indefinido.

- [ ] **Step 3: Migration**

```elixir
# priv/repo/migrations/<ts>_create_patients.exs
defmodule Ravanshenasi.Repo.Migrations.CreatePatients do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:patients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      # Composite FK: owner must be a user OF THE SAME TENANT.
      add :user_id,
          references(:users, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :restrict),
          null: false

      add :name, :string, null: false
      add :birth_date, :date
      add :phone, :string
      add :email, :string
      add :chief_complaint, :text
      add :relevant_history, :text
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create index(:patients, [:tenant_id, :user_id])
    create index(:patients, [:tenant_id, :user_id, :status])
    create index(:patients, [:tenant_id, :user_id, :name])
    # Composite-FK target for patient_frameworks.
    create unique_index(:patients, [:id, :tenant_id])

    enable_tenant_rls("patients")
  end
end
```

- [ ] **Step 4: Schema**

```elixir
# lib/ravanshenasi/patients/patient.ex
defmodule Ravanshenasi.Patients.Patient do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "patients" do
    field :name, :string
    field :birth_date, :date
    field :phone, :string
    field :email, :string
    field :chief_complaint, :string
    field :relevant_history, :string
    field :status, Ecto.Enum, values: [:active, :inactive, :waitlist], default: :active

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :user, Ravanshenasi.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "User-editable fields (tenant_id/user_id are set server-side, never from the form)."
  def changeset(patient, attrs) do
    patient
    |> cast(attrs, [:name, :birth_date, :phone, :email, :chief_complaint, :relevant_history, :status])
    |> validate_required([:name])
  end
end
```

- [ ] **Step 5: Teste da FK composta cross-tenant (falha → passa)**

```elixir
# adicionar a test/ravanshenasi/patients/patient_test.exs
defmodule Ravanshenasi.Patients.PatientFkTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.Repo
  alias Ravanshenasi.Patients.Patient

  test "FK composta rejeita paciente com user_id de OUTRO tenant" do
    a = user_scope_fixture()
    b = user_scope_fixture()

    # tenta criar paciente no tenant A com dono do tenant B — via bypass (fura RLS),
    # então a defesa que resta é a FK composta (tenant_id, user_id).
    assert_raise Ecto.ConstraintError, fn ->
      Repo.with_registration_bypass(fn ->
        %Patient{tenant_id: a.tenant.id, user_id: b.user.id, name: "X"}
        |> Ecto.Changeset.change()
        |> Repo.insert!()
      end)
    end
  end
end
```

- [ ] **Step 6: Migrar + testar**

Run: `mix ecto.migrate && mix test test/ravanshenasi/patients/patient_test.exs`
Expected: PASS (changeset 3 + FK 1).

- [ ] **Step 7: Commit**

```
✨ feat(patients): patients schema + migration with composite FK and RLS
```

---

## Task 7: `Patients` context — CRUD scoped + busca/filtro

**Files:**
- Create: `lib/ravanshenasi/patients.ex`
- Test: `test/ravanshenasi/patients_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi/patients_test.exs
defmodule Ravanshenasi.PatientsTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.Patients

  test "create + list scoped por dono" do
    s = user_scope_fixture()
    assert {:ok, p} = Patients.create_patient(s, %{name: "Maria"})
    assert p.user_id == s.user.id and p.tenant_id == s.tenant.id
    assert [%{name: "Maria"}] = Patients.list_patients(s)
  end

  test "outro user do mesmo tenant (clínica) não vê o paciente" do
    admin = clinic_admin_scope_fixture()
    s = therapist_scope_fixture(admin.tenant)
    other = therapist_scope_fixture(admin.tenant)
    {:ok, p} = Patients.create_patient(s, %{name: "Maria"})

    assert Patients.list_patients(other) == []
    assert Patients.get_patient(other, p.id) == nil
  end

  test "busca por nome (ilike) e filtro por status" do
    s = user_scope_fixture()
    {:ok, _} = Patients.create_patient(s, %{name: "Ana Paula", status: :active})
    {:ok, _} = Patients.create_patient(s, %{name: "Bruno", status: :waitlist})

    assert [%{name: "Ana Paula"}] = Patients.list_patients(s, q: "ana")
    assert [%{name: "Bruno"}] = Patients.list_patients(s, status: :waitlist)
  end

  test "inactivate_patient faz soft-delete" do
    s = user_scope_fixture()
    {:ok, p} = Patients.create_patient(s, %{name: "Maria"})
    assert {:ok, p} = Patients.inactivate_patient(s, p)
    assert p.status == :inactive
    assert Patients.list_patients(s, status: :active) == []
  end

  test "admin de clínica não cria paciente" do
    s = clinic_admin_scope_fixture()
    assert {:error, :unauthorized} = Patients.create_patient(s, %{name: "X"})
  end
end
```

- [ ] **Step 2: Rodar — falha**

Run: `mix test test/ravanshenasi/patients_test.exs`
Expected: FAIL — context indefinido.

- [ ] **Step 3: Implementar**

```elixir
# lib/ravanshenasi/patients.ex
defmodule Ravanshenasi.Patients do
  @moduledoc "Patient records, scoped to the owning practitioner."

  import Ecto.Query

  alias Ravanshenasi.Repo
  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Patients.Patient

  @doc "Lists the scope's patients. opts: :status (filter), :q (name ilike)."
  def list_patients(%Scope{} = scope, opts \\ []) do
    transact_tenant(scope, fn ->
      Patient
      |> scoped(scope)
      |> filter_status(opts[:status])
      |> search_name(opts[:q])
      |> order_by([p], asc: p.name)
      |> Repo.all()
    end)
  end

  def get_patient(%Scope{} = scope, id) do
    transact_tenant(scope, fn -> Patient |> scoped(scope) |> Repo.get(id) end)
  end

  def get_patient!(%Scope{} = scope, id) do
    transact_tenant(scope, fn -> Patient |> scoped(scope) |> Repo.get!(id) end)
  end

  def create_patient(%Scope{} = scope, attrs) do
    if Scope.clinical_access?(scope) do
      transact_tenant(scope, fn ->
        %Patient{tenant_id: scope.tenant.id, user_id: scope.user.id}
        |> Patient.changeset(attrs)
        |> Repo.insert()
      end)
    else
      {:error, :unauthorized}
    end
  end

  def update_patient(%Scope{} = scope, %Patient{} = patient, attrs) do
    if owns?(scope, patient) do
      transact_tenant(scope, fn -> patient |> Patient.changeset(attrs) |> Repo.update() end)
    else
      {:error, :unauthorized}
    end
  end

  def inactivate_patient(%Scope{} = scope, %Patient{} = patient) do
    update_patient(scope, patient, %{status: :inactive})
  end

  def change_patient(%Patient{} = patient, attrs \\ %{}), do: Patient.changeset(patient, attrs)

  defp scoped(query, scope) do
    from p in query, where: p.tenant_id == ^scope.tenant.id and p.user_id == ^scope.user.id
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: from(p in query, where: p.status == ^status)

  defp search_name(query, nil), do: query
  defp search_name(query, ""), do: query
  defp search_name(query, q), do: from(p in query, where: ilike(p.name, ^"%#{q}%"))

  defp owns?(scope, %Patient{user_id: uid, tenant_id: tid}) do
    Scope.clinical_access?(scope) and scope.user.id == uid and scope.tenant.id == tid
  end

  defdelegate transact_tenant(scope, fun), to: Repo
end
```

- [ ] **Step 4: Rodar — passa**

Run: `mix test test/ravanshenasi/patients_test.exs`
Expected: PASS (5 testes).

- [ ] **Step 5: Commit**

```
✨ feat(patients): scoped CRUD with search, status filter and soft-delete
```

---

## Task 8: Join `patient_frameworks` (schema + migration)

**Files:**
- Create: `lib/ravanshenasi/patients/patient_framework.ex`
- Create: `priv/repo/migrations/<ts>_create_patient_frameworks.exs`
- Test: `test/ravanshenasi/patients/patient_framework_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi/patients/patient_framework_test.exs
defmodule Ravanshenasi.Patients.PatientFrameworkTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Patients.PatientFramework

  test "changeset exige patient_id e thinking_framework_id" do
    cs = PatientFramework.changeset(%PatientFramework{}, %{})
    refute cs.valid?
  end
end
```

- [ ] **Step 2: Rodar — falha**

Run: `mix test test/ravanshenasi/patients/patient_framework_test.exs`
Expected: FAIL — módulo indefinido.

- [ ] **Step 3: Migration**

```elixir
# priv/repo/migrations/<ts>_create_patient_frameworks.exs
defmodule Ravanshenasi.Repo.Migrations.CreatePatientFrameworks do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    create table(:patient_frameworks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      # Composite FKs: patient AND framework must belong to the same tenant.
      add :patient_id,
          references(:patients, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :delete_all),
          null: false

      add :thinking_framework_id,
          references(:thinking_frameworks, type: :binary_id, with: [tenant_id: :tenant_id], on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:patient_frameworks, [:patient_id, :thinking_framework_id])
    create index(:patient_frameworks, [:tenant_id])

    enable_tenant_rls("patient_frameworks")
  end
end
```

- [ ] **Step 4: Schema**

```elixir
# lib/ravanshenasi/patients/patient_framework.ex
defmodule Ravanshenasi.Patients.PatientFramework do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "patient_frameworks" do
    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :patient, Ravanshenasi.Patients.Patient
    belongs_to :thinking_framework, Ravanshenasi.Frameworks.ThinkingFramework

    timestamps(type: :utc_datetime)
  end

  def changeset(pf, attrs) do
    pf
    |> cast(attrs, [:tenant_id, :patient_id, :thinking_framework_id])
    |> validate_required([:tenant_id, :patient_id, :thinking_framework_id])
    |> unique_constraint([:patient_id, :thinking_framework_id])
  end
end
```

- [ ] **Step 5: Migrar + testar**

Run: `mix ecto.migrate && mix test test/ravanshenasi/patients/patient_framework_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```
✨ feat(patients): patient_frameworks join with composite FKs and RLS
```

---

## Task 9: Associação paciente↔framework no `Patients`

**Files:**
- Modify: `lib/ravanshenasi/patients.ex`
- Test: `test/ravanshenasi/patients_association_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi/patients_association_test.exs
defmodule Ravanshenasi.PatientsAssociationTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.{Patients, Frameworks}

  setup do
    s = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(s, %{name: "Maria"})
    catalog = Frameworks.list_frameworks(s) |> hd()
    %{scope: s, patient: patient, framework: catalog}
  end

  test "activate/deactivate por presença na join", %{scope: s, patient: p, framework: f} do
    assert {:ok, _} = Patients.activate_framework(s, p, f)
    assert [%{id: id}] = Patients.list_patient_frameworks(s, p)
    assert id == f.id

    assert :ok = Patients.deactivate_framework(s, p, f)
    assert Patients.list_patient_frameworks(s, p) == []
  end

  test "não associa framework não-visível (de outro profissional)", %{scope: s, patient: p} do
    other = user_scope_fixture()
    {:ok, foreign} = Frameworks.create_own_framework(other, %{name: "Alheio", description: "x"})
    assert {:error, :not_found} = Patients.activate_framework(s, p, foreign)
  end
end
```

- [ ] **Step 2: Rodar — falha**

Run: `mix test test/ravanshenasi/patients_association_test.exs`
Expected: FAIL — funções indefinidas.

- [ ] **Step 3: Implementar**

Adicione ao `lib/ravanshenasi/patients.ex` (e os aliases necessários):

```elixir
alias Ravanshenasi.Patients.PatientFramework
alias Ravanshenasi.Frameworks
alias Ravanshenasi.Frameworks.ThinkingFramework

@doc "Active frameworks of a patient (presence in the join = active)."
def list_patient_frameworks(%Scope{} = scope, %Patient{} = patient) do
  transact_tenant(scope, fn ->
    Repo.all(
      from f in ThinkingFramework,
        join: pf in PatientFramework,
        on: pf.thinking_framework_id == f.id,
        where: pf.patient_id == ^patient.id,
        order_by: [asc: f.name]
    )
  end)
end

@doc "Activates a framework on a patient. Validates ownership and framework visibility."
def activate_framework(%Scope{} = scope, %Patient{} = patient, %ThinkingFramework{} = framework) do
  cond do
    not owns?(scope, patient) ->
      {:error, :unauthorized}

    not visible?(scope, framework) ->
      {:error, :not_found}

    true ->
      transact_tenant(scope, fn ->
        %PatientFramework{tenant_id: scope.tenant.id}
        |> PatientFramework.changeset(%{patient_id: patient.id, thinking_framework_id: framework.id})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:patient_id, :thinking_framework_id])
      end)
  end
end

@doc "Deactivates a framework on a patient (removes from the join)."
def deactivate_framework(%Scope{} = scope, %Patient{} = patient, %ThinkingFramework{} = framework) do
  if owns?(scope, patient) do
    transact_tenant(scope, fn ->
      Repo.delete_all(
        from pf in PatientFramework,
          where: pf.patient_id == ^patient.id and pf.thinking_framework_id == ^framework.id
      )
    end)

    :ok
  else
    {:error, :unauthorized}
  end
end

# Visible = tenant catalog (user_id NULL) or owned by the scope's user.
defp visible?(_scope, %ThinkingFramework{user_id: nil}), do: true
defp visible?(scope, %ThinkingFramework{user_id: uid}), do: scope.user.id == uid
```

- [ ] **Step 4: Rodar — passa**

Run: `mix test test/ravanshenasi/patients_association_test.exs`
Expected: PASS (2 testes).

- [ ] **Step 5: Commit**

```
✨ feat(patients): activate/deactivate frameworks with visibility checks
```

---

## Task 10: Teste-âncora de isolamento clínico

**Files:**
- Test: `test/ravanshenasi/clinical_isolation_test.exs`

- [ ] **Step 1: Teste (deve passar de primeira — valida o que já construímos)**

```elixir
# test/ravanshenasi/clinical_isolation_test.exs
defmodule Ravanshenasi.ClinicalIsolationTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.{Patients, Repo}
  alias Ravanshenasi.Patients.Patient

  test "paciente do user A é invisível pro user B do MESMO tenant clínica (scope user_id)" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, _} = Patients.create_patient(a, %{name: "Sigiloso"})

    assert Patients.list_patients(b) == []
  end

  test "RLS fail-closed: sem GUC de tenant, query direta retorna 0 linhas" do
    a = user_scope_fixture()
    {:ok, _} = Patients.create_patient(a, %{name: "Sigiloso"})

    # nenhum transact_tenant ativo → app.current_tenant_id vazio → fail-closed
    assert Repo.all(Patient) == []
  end

  test "tenant B não enxerga paciente do tenant A (RLS tenant_id)" do
    a = user_scope_fixture()
    b = user_scope_fixture()
    {:ok, _} = Patients.create_patient(a, %{name: "Sigiloso"})

    assert Patients.list_patients(b) == []
  end
end
```

- [ ] **Step 2: Rodar — passa**

Run: `mix test test/ravanshenasi/clinical_isolation_test.exs`
Expected: PASS (3 testes). Se "fail-closed" pegar linhas, cheque que o `transact_tenant` está resetando o GUC (Fatia 0) — não deveria regredir.

- [ ] **Step 3: Commit**

```
✅ test(patients): clinical isolation anchor (scope user_id + RLS tenant_id)
```

---

## Task 11: LiveViews de pacientes (index, show, form)

**Files:**
- Create: `lib/ravanshenasi_web/live/patient_live/{index,show,form}.ex`
- Modify: `lib/ravanshenasi_web/router.ex`
- Test: `test/ravanshenasi_web/live/patient_live_test.exs`

- [ ] **Step 1: Teste de integração (falha)**

```elixir
# test/ravanshenasi_web/live/patient_live_test.exs
defmodule RavanshenasiWeb.PatientLiveTest do
  use RavanshenasiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures

  setup %{conn: conn} do
    scope = user_scope_fixture()
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  test "cria paciente pelo form e aparece no index", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/pacientes/novo")
    lv |> form("#patient-form", %{"patient" => %{"name" => "Joana"}}) |> render_submit()

    {:ok, _idx, html} = live(conn, ~p"/pacientes")
    assert html =~ "Joana"
  end

  test "busca filtra a lista", %{conn: conn, scope: scope} do
    Ravanshenasi.Patients.create_patient(scope, %{name: "Carlos"})
    Ravanshenasi.Patients.create_patient(scope, %{name: "Daniela"})

    {:ok, lv, _} = live(conn, ~p"/pacientes")
    html = lv |> form("#patient-search", %{"q" => "carl"}) |> render_change()
    assert html =~ "Carlos"
    refute html =~ "Daniela"
  end
end
```

> `log_in_user/2` é o helper do `ConnCase` da Fatia 0. Confirme a assinatura (pode aceitar `opts`).

- [ ] **Step 2: Rodar — falha**

Run: `mix test test/ravanshenasi_web/live/patient_live_test.exs`
Expected: FAIL — rotas/LV inexistentes.

- [ ] **Step 3: Rotas**

Em `lib/ravanshenasi_web/router.ex`, na `live_session` autenticada existente (a que monta o `current_scope`; confirme o nome do `on_mount` gerado, ex.: `:require_authenticated`):

```elixir
live "/pacientes", PatientLive.Index, :index
live "/pacientes/novo", PatientLive.Form, :new
live "/pacientes/:id", PatientLive.Show, :show
live "/pacientes/:id/editar", PatientLive.Form, :edit
```

> Use o mesmo namespace/escopo dos LiveViews gerados (o router já tem `scope "/", RavanshenasiWeb`). Os módulos abaixo são `RavanshenasiWeb.PatientLive.*`.

- [ ] **Step 4: `PatientLive.Index`**

```elixir
# lib/ravanshenasi_web/live/patient_live/index.ex
defmodule RavanshenasiWeb.PatientLive.Index do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Patients

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, q: "", status: nil) |> load()}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(q: q) |> load()}
  end

  defp load(socket) do
    patients = Patients.list_patients(socket.assigns.current_scope, q: socket.assigns.q, status: socket.assigns.status)
    assign(socket, patients: patients)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {gettext("Patients")}
        <:actions>
          <.button navigate={~p"/pacientes/novo"}>{gettext("New patient")}</.button>
        </:actions>
      </.header>

      <form id="patient-search" phx-change="search">
        <.input type="text" name="q" value={@q} placeholder={gettext("Search by name")} />
      </form>

      <ul id="patients">
        <li :for={p <- @patients}>
          <.link navigate={~p"/pacientes/#{p.id}"}>{p.name}</.link> — {p.status}
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 5: `PatientLive.Form` (new/edit)**

```elixir
# lib/ravanshenasi_web/live/patient_live/form.ex
defmodule RavanshenasiWeb.PatientLive.Form do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Patients
  alias Ravanshenasi.Patients.Patient

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    assign(socket, page_title: gettext("New patient"), patient: %Patient{}, form: to_form(Patients.change_patient(%Patient{})))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    patient = Patients.get_patient!(socket.assigns.current_scope, id)
    assign(socket, page_title: gettext("Edit patient"), patient: patient, form: to_form(Patients.change_patient(patient)))
  end

  @impl true
  def handle_event("validate", %{"patient" => params}, socket) do
    form = socket.assigns.patient |> Patients.change_patient(params) |> to_form(action: :validate)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"patient" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case Patients.create_patient(socket.assigns.current_scope, params) do
      {:ok, p} -> {:noreply, socket |> put_flash(:info, gettext("Patient created")) |> push_navigate(to: ~p"/pacientes/#{p.id}")}
      {:error, %Ecto.Changeset{} = cs} -> {:noreply, assign(socket, form: to_form(cs))}
      {:error, :unauthorized} -> {:noreply, socket |> put_flash(:error, gettext("Not authorized")) |> push_navigate(to: ~p"/pacientes")}
    end
  end

  defp save(socket, :edit, params) do
    case Patients.update_patient(socket.assigns.current_scope, socket.assigns.patient, params) do
      {:ok, p} -> {:noreply, socket |> put_flash(:info, gettext("Patient updated")) |> push_navigate(to: ~p"/pacientes/#{p.id}")}
      {:error, %Ecto.Changeset{} = cs} -> {:noreply, assign(socket, form: to_form(cs))}
      {:error, :unauthorized} -> {:noreply, socket |> put_flash(:error, gettext("Not authorized")) |> push_navigate(to: ~p"/pacientes")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>{@page_title}</.header>
      <.form for={@form} id="patient-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} label={gettext("Name")} required />
        <.input field={@form[:birth_date]} type="date" label={gettext("Birth date")} />
        <.input field={@form[:phone]} label={gettext("Phone")} />
        <.input field={@form[:email]} type="email" label={gettext("Email")} />
        <.input field={@form[:chief_complaint]} type="textarea" label={gettext("Chief complaint")} />
        <.input field={@form[:relevant_history]} type="textarea" label={gettext("Relevant history")} />
        <.input field={@form[:status]} type="select" label={gettext("Status")}
                options={[{gettext("Active"), :active}, {gettext("Inactive"), :inactive}, {gettext("Waitlist"), :waitlist}]} />
        <.button phx-disable-with={gettext("Saving...")}>{gettext("Save")}</.button>
      </.form>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 6: `PatientLive.Show` (perfil + associação de frameworks)**

```elixir
# lib/ravanshenasi_web/live/patient_live/show.ex
defmodule RavanshenasiWeb.PatientLive.Show do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.{Patients, Frameworks}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    patient = Patients.get_patient!(scope, id)
    {:ok, socket |> assign(patient: patient) |> load_frameworks()}
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

  defp load_frameworks(socket) do
    scope = socket.assigns.current_scope
    all = Frameworks.list_frameworks(scope)
    active_ids = Patients.list_patient_frameworks(scope, socket.assigns.patient) |> MapSet.new(& &1.id)
    assign(socket, all_frameworks: all, active_ids: active_ids)
  end

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
            <input type="checkbox" checked={MapSet.member?(@active_ids, f.id)}
              phx-click="toggle-framework"
              phx-value-id={f.id}
              phx-value-on={to_string(not MapSet.member?(@active_ids, f.id))} />
            {f.name}
          </label>
        </li>
      </ul>
      <.button navigate={~p"/pacientes/#{@patient.id}/editar"}>{gettext("Edit")}</.button>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 7: Rodar — passa**

Run: `mix test test/ravanshenasi_web/live/patient_live_test.exs`
Expected: PASS (2 testes). Ajuste seletores/labels conforme os componentes reais (`<.input>`, `Layouts.app`).

- [ ] **Step 8: Commit**

```
✨ feat(live): patient index, form and show with framework association
```

---

## Task 12: LiveView de frameworks + navegação por papel

**Files:**
- Create: `lib/ravanshenasi_web/live/framework_live/index.ex`
- Modify: `lib/ravanshenasi_web/router.ex` (rota)
- Modify: layout/nav (esconder Pacientes pro admin de clínica; Linhas visível p/ admin)
- Test: `test/ravanshenasi_web/live/framework_live_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi_web/live/framework_live_test.exs
defmodule RavanshenasiWeb.FrameworkLiveTest do
  use RavanshenasiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures

  test "solo cria linha própria e ela aparece", %{conn: conn} do
    scope = user_scope_fixture()
    conn = log_in_user(conn, scope.user)
    {:ok, lv, _} = live(conn, ~p"/linhas")
    html = lv |> form("#framework-form", %{"framework" => %{"name" => "Sistêmica", "description" => "x"}}) |> render_submit()
    assert html =~ "Sistêmica"
  end
end
```

- [ ] **Step 2: Rodar — falha**

Run: `mix test test/ravanshenasi_web/live/framework_live_test.exs`
Expected: FAIL.

- [ ] **Step 3: Rota**

```elixir
# na live_session autenticada
live "/linhas", FrameworkLive.Index, :index
```

- [ ] **Step 4: `FrameworkLive.Index`**

```elixir
# lib/ravanshenasi_web/live/framework_live/index.ex
defmodule RavanshenasiWeb.FrameworkLive.Index do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Frameworks

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(form: empty_form()) |> load()}
  end

  @impl true
  def handle_event("create", %{"framework" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      if Ravanshenasi.Accounts.Scope.admin?(scope) and not Ravanshenasi.Accounts.Scope.clinical_access?(scope) do
        # clinic admin manages the tenant catalog
        Frameworks.create_tenant_framework(scope, params)
      else
        Frameworks.create_own_framework(scope, params)
      end

    case result do
      {:ok, _} -> {:noreply, socket |> assign(form: empty_form()) |> load()}
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, gettext("Not authorized"))}
      {:error, %Ecto.Changeset{} = cs} -> {:noreply, assign(socket, form: to_form(cs))}
    end
  end

  defp empty_form, do: to_form(%{"name" => "", "description" => ""}, as: :framework)
  defp load(socket), do: assign(socket, frameworks: Frameworks.list_frameworks(socket.assigns.current_scope))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>{gettext("Lines of thought")}</.header>
      <.form for={@form} id="framework-form" phx-submit="create">
        <.input field={@form[:name]} label={gettext("Name")} required />
        <.input field={@form[:description]} type="textarea" label={gettext("Guiding principles")} />
        <.button>{gettext("Add line")}</.button>
      </.form>
      <ul id="frameworks">
        <li :for={f <- @frameworks}>{f.name}{if f.is_predefined, do: " ⭐"}</li>
      </ul>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 5: Navegação por papel**

No layout de navegação (o menu da `Layouts.app` — confirme o arquivo, ex.: `lib/ravanshenasi_web/components/layouts.ex`), envolva os links por papel usando o `@current_scope`:

```heex
<.link :if={Ravanshenasi.Accounts.Scope.clinical_access?(@current_scope)} navigate={~p"/pacientes"}>
  {gettext("Patients")}
</.link>
<.link :if={Ravanshenasi.Accounts.Scope.clinical_access?(@current_scope) or Ravanshenasi.Accounts.Scope.admin?(@current_scope)} navigate={~p"/linhas"}>
  {gettext("Lines of thought")}
</.link>
```

> Pacientes só pra quem atende; Linhas pra quem atende **ou** admin (gerencia catálogo). A autorização real está no context (Tasks 4/7) — isto é só UX.

- [ ] **Step 6: Rodar — passa**

Run: `mix test test/ravanshenasi_web/live/framework_live_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```
✨ feat(live): lines-of-thought management + role-aware navigation
```

---

## Task 13: Encolher docs legados + fechamento

**Files:**
- Modify: `docs/FEATURES.md`, `docs/DATA_MODEL.md`
- (sem código novo)

- [ ] **Step 1: Encolher `docs/FEATURES.md`**

Remova as seções **#1 Autenticação e Multi-tenancy** (Fatia 0), **#2 Cadastro de Pacientes** e **#7 Configuração de Linhas de Pensamento** (esta fatia). Mantenha #3–#6 e #8 (fatias futuras). No topo, adicione uma linha: `> Migrado para specs/: #1 (Fatia 0), #2 e #7 (Fatia 1). Restantes são backlog.`

- [ ] **Step 2: Encolher `docs/DATA_MODEL.md`**

Remova as tabelas já especificadas: `tenants`, `users`, `invitations` (Fatia 0), `patients`, `thinking_frameworks`, `patient_frameworks` (esta fatia). Mantenha `sessions`, `records`, `audio_uploads`. Adicione no topo a mesma nota de migração.

- [ ] **Step 3: Verificar precommit**

Run: `mix precommit`
Expected: compile sem warnings, `format --check-formatted` ok, **Credo `--strict` 0 issues**, **todos os testes verdes**.

> Se o Credo reclamar de alias/nesting/moduledoc nos módulos novos, ajuste (alias no topo, `@moduledoc`). Não desabilite checks.

- [ ] **Step 4: Commit**

```
📝 docs: shrink legacy FEATURES/DATA_MODEL (slices 0–1 absorbed)
```

---

## Definition of Done (verificação contra o spec)

- [ ] `patients`, `thinking_frameworks`, `patient_frameworks` com `enable_tenant_rls`. *(Tasks 3, 6, 8)*
- [ ] Integridade tenant-aware: unique `(id, tenant_id)` + FKs compostas; FK rejeita cross-tenant. *(Tasks 2, 3, 6, 8)*
- [ ] CRUD de pacientes scoped (busca/filtro); soft-delete `:inactive`. *(Tasks 6, 7, 11)*
- [ ] Seed das 7 no nível tenant via `register_solo`/`register_clinic`; backfill sob bypass; `accept_invitation` herda. *(Tasks 4, 5)*
- [ ] `list_frameworks` união simples (catálogo + próprios); herança testada. *(Task 4)*
- [ ] Associação ativar/desativar; cross-user bloqueada. *(Task 9)*
- [ ] Autorização no context: admin de clínica → `{:error, :unauthorized}` em pacientes/frameworks próprios. *(Tasks 1, 4, 7)*
- [ ] Teste-âncora clínico passa (scope `user_id` + RLS `tenant_id`). *(Task 10)*
- [ ] Nav por papel: admin de clínica vê Linhas, não vê Pacientes. *(Task 12)*
- [ ] Docs legados encolhidos. *(Task 13)*
- [ ] `mix precommit` verde. *(Task 13)*

---

## Notas de risco para o executor

1. **`nulls_distinct: false`** no unique index dos frameworks exige Ecto recente; se a opção não existir, crie o índice via `execute/2` com SQL cru (`... NULLS NOT DISTINCT`).
2. **Composite FK (`with:`)** requer unique index na tabela-alvo na ordem `(id, tenant_id)` (Tasks 2/3/6 criam). Se a migração de FK falhar com "no unique constraint matching given keys", confira que o índice-alvo foi criado antes.
3. **Seed via `insert_all`** não passa por changeset: as rows incluem `id` (UUID gerado), `inserted_at`/`updated_at` e `is_predefined` explícitos. Não remover esses campos.
4. **`async: false`** em todo teste que toca `transact_tenant`/bypass no corpo (race do Sandbox). Testes de changeset puro podem ser `async: true`.
5. **Backfill** roda sob `SET LOCAL app.auth_bypass='on'` e é idempotente (`WHERE NOT EXISTS`). Não rodar sem o bypass — RLS bloquearia.
6. **Nomes de `on_mount`/helpers gerados** (ex.: `:require_authenticated`, `log_in_user/2`): confirme no código da Fatia 0 antes de usar nas rotas/testes.
