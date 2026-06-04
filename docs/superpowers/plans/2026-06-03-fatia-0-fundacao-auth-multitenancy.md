# Fatia 0 — Fundação (Auth + Multi-tenancy RLS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar a fundação do PsiCare — autenticação (magic link + senha), multi-tenancy com isolamento real por `tenant_id` + RLS fail-closed, papéis admin/therapist e onboarding solo + clínica com convites — sobre o scaffold Phoenix 1.8 existente.

**Architecture:** Duas camadas de isolamento. (1) Scope explícito: o `Scope` do Phoenix 1.8 carrega `{user, tenant, role}` e todo context filtra por ele. (2) RLS no Postgres como rede de segurança: policies fail-closed comparando `tenant_id` com o GUC `app.current_tenant_id`, setado só via `Repo.transact_tenant/2`; lookups/criações pré-tenant furam o RLS via `with_auth_bypass/1` e `with_registration_bypass/1` (mesmo GUC `app.auth_bypass`, nomes separados por auditoria).

**Tech Stack:** Elixir 1.19 · Phoenix 1.8.7 · LiveView 1.1 · Ecto/Postgrex · TimescaleDB HA pg17 · Swoosh · `mix phx.gen.auth` (magic link + senha + sudo mode).

**Spec de referência:** `docs/superpowers/specs/2026-06-03-fundacao-auth-multitenancy-design.md`

---

## Convenções deste plano

- O projeto usa **binary IDs** (UUID). Todo PK/FK é `:binary_id`.
- Enums (`plan`, `role`) → coluna `:string` + `Ecto.Enum` no schema (migrations reversíveis, sem tipo enum nativo do PG).
- **Comandos de teste:** `mix test caminho/arquivo.exs:LINHA`.
- **Sempre** rodar `mix test` antes de cada commit do task. Mensagens de commit em pt-BR, imperativo curto.
- Onde um task **estende arquivo gerado** pelo `phx.gen.auth`, o passo manda **abrir o arquivo e localizar** o ponto de encaixe — os nomes internos do gerador (ex.: nome exato de um `on_mount`) podem variar por patch; o plano dá o alvo e o código a inserir.

---

## File Structure

**Criados por nós:**
- `lib/ravanshenasi/accounts/tenant.ex` — schema `Tenant` (name, plan).
- `lib/ravanshenasi/accounts/invitation.ex` — schema `Invitation` (convite de membro).
- `lib/ravanshenasi/rls.ex` — helper de migration `enable_tenant_rls/2` (chamável de migrations).
- `priv/repo/migrations/*_create_tenants.exs`
- `priv/repo/migrations/*_create_invitations.exs`
- `priv/repo/migrations/*_enable_tenant_rls.exs`
- `priv/repo/migrations/*_add_tenant_fields_to_users.exs`
- `lib/ravanshenasi_web/live/org/` — LiveViews de gestão (registro clínica, membros, convites).
- testes correspondentes em `test/`.

**Estendidos (gerados por `phx.gen.auth`):**
- `lib/ravanshenasi/accounts.ex` — +`register_solo/1`, `register_clinic/1`, convites, membros.
- `lib/ravanshenasi/accounts/user.ex` — +`tenant_id`, `role`, `name`.
- `lib/ravanshenasi/accounts/scope.ex` — +`tenant`, `put_tenant/2`, `admin?/1`, `therapist?/1`.
- `lib/ravanshenasi/repo.ex` — +`transact_tenant/2`, `with_auth_bypass/1`, `with_registration_bypass/1`.
- `lib/ravanshenasi_web/user_auth.ex` — on_mount/plug injeta `tenant` no scope + `require_admin`.

---

## Task 1: Gerar a base de autenticação com `phx.gen.auth`

**Files:**
- Create (gerados): `lib/ravanshenasi/accounts.ex`, `lib/ravanshenasi/accounts/{user,user_token,user_notifier,scope}.ex`, `lib/ravanshenasi_web/user_auth.ex`, `lib/ravanshenasi_web/live/user_live/*`, `priv/repo/migrations/*_create_users_auth_tables.exs`, testes em `test/`.
- Modify (gerados): `mix.exs` (deps `bcrypt_pbkdf`/`argon2`), `router.ex`, `lib/ravanshenasi_web/components/layouts.ex`.

- [ ] **Step 1: Confirmar banco no ar**

Run: `docker compose ps && mix ecto.create`
Expected: container TimescaleDB `healthy`; `The database for Ravanshenasi.Repo has been created` (ou "already up").

- [ ] **Step 2: Rodar o gerador**

Run: `mix phx.gen.auth Accounts User users`
Quando perguntar "Do you want to create a LiveView based authentication system?", responda **Y**.
Expected: lista de arquivos criados/injetados; instrução pra rodar `mix deps.get`.

- [ ] **Step 3: Instalar deps e migrar**

Run: `mix deps.get && mix ecto.migrate`
Expected: compila; migration de `users`/`users_tokens` aplicada (inclui `CREATE EXTENSION citext`).

- [ ] **Step 4: Rodar a suíte gerada (baseline verde)**

Run: `mix test`
Expected: todos os testes gerados pelo `phx.gen.auth` passam (registro, login magic link, senha, sudo mode, settings).

- [ ] **Step 5: Inspecionar o que foi gerado (orientação, sem editar)**

Run: `sed -n '1,40p' lib/ravanshenasi/accounts/scope.ex && grep -n "on_mount\|def fetch_current_scope" lib/ravanshenasi_web/user_auth.ex`
Anote: o nome exato dos `on_mount` (ex.: `:mount_current_scope`, `:require_authenticated`) e a função de plug que carrega o scope. Tasks 9 e 13 vão estendê-los.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: gera base de auth (phx.gen.auth) com magic link + senha + sudo"
```

---

## Task 2: Schema e migration de `tenants`

**Files:**
- Create: `lib/ravanshenasi/accounts/tenant.ex`
- Create: `priv/repo/migrations/<ts>_create_tenants.exs`
- Test: `test/ravanshenasi/accounts/tenant_test.exs`

- [ ] **Step 1: Escrever o teste do changeset (falha)**

```elixir
# test/ravanshenasi/accounts/tenant_test.exs
defmodule Ravanshenasi.Accounts.TenantTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts.Tenant

  test "changeset exige name e plan válido" do
    cs = Tenant.changeset(%Tenant{}, %{name: "Clínica X", plan: :clinic})
    assert cs.valid?
  end

  test "changeset rejeita plan fora do enum" do
    cs = Tenant.changeset(%Tenant{}, %{name: "X", plan: :enterprise})
    refute cs.valid?
    assert %{plan: ["is invalid"]} = errors_on(cs)
  end

  test "changeset exige name" do
    cs = Tenant.changeset(%Tenant{}, %{plan: :solo})
    refute cs.valid?
    assert %{name: ["can't be blank"]} = errors_on(cs)
  end
end
```

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi/accounts/tenant_test.exs`
Expected: FAIL — `Ravanshenasi.Accounts.Tenant.__struct__/0 is undefined`.

- [ ] **Step 3: Criar a migration**

```elixir
# priv/repo/migrations/<ts>_create_tenants.exs
defmodule Ravanshenasi.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  def change do
    create table(:tenants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :plan, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
```

- [ ] **Step 4: Criar o schema**

```elixir
# lib/ravanshenasi/accounts/tenant.ex
defmodule Ravanshenasi.Accounts.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenants" do
    field :name, :string
    field :plan, Ecto.Enum, values: [:solo, :clinic]

    has_many :users, Ravanshenasi.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :plan])
    |> validate_required([:name, :plan])
  end
end
```

- [ ] **Step 5: Migrar e testar**

Run: `mix ecto.migrate && mix test test/ravanshenasi/accounts/tenant_test.exs`
Expected: PASS (3 testes).

- [ ] **Step 6: Commit**

```bash
git add lib/ravanshenasi/accounts/tenant.ex priv/repo/migrations/*_create_tenants.exs test/ravanshenasi/accounts/tenant_test.exs
git commit -m "feat: schema e migration de tenants"
```

---

## Task 3: Estender `users` com `tenant_id`, `role`, `name`

**Files:**
- Create: `priv/repo/migrations/<ts>_add_tenant_fields_to_users.exs`
- Modify: `lib/ravanshenasi/accounts/user.ex`
- Test: `test/ravanshenasi/accounts/user_tenant_fields_test.exs`

- [ ] **Step 1: Escrever o teste (falha)**

```elixir
# test/ravanshenasi/accounts/user_tenant_fields_test.exs
defmodule Ravanshenasi.Accounts.UserTenantFieldsTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts.User

  test "tenant_changeset exige tenant_id, name e role válido" do
    cs = User.tenant_changeset(%User{}, %{tenant_id: Ecto.UUID.generate(), name: "Dra. Ana", role: :therapist})
    assert cs.valid?
  end

  test "tenant_changeset rejeita role fora do enum" do
    cs = User.tenant_changeset(%User{}, %{tenant_id: Ecto.UUID.generate(), name: "X", role: :root})
    refute cs.valid?
    assert %{role: ["is invalid"]} = errors_on(cs)
  end
end
```

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi/accounts/user_tenant_fields_test.exs`
Expected: FAIL — `function Ravanshenasi.Accounts.User.tenant_changeset/2 is undefined`.

- [ ] **Step 3: Criar a migration**

```elixir
# priv/repo/migrations/<ts>_add_tenant_fields_to_users.exs
defmodule Ravanshenasi.Repo.Migrations.AddTenantFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :restrict), null: false
      add :name, :string, null: false
      add :role, :string, null: false
    end

    create index(:users, [:tenant_id])
  end
end
```

> A coluna `users.email` já é `citext` com índice unique **global** (gerado pelo `phx.gen.auth`) — nada a fazer aqui. Confirme com `grep -n "email" priv/repo/migrations/*_create_users_auth_tables.exs`.

- [ ] **Step 4: Estender o schema `User`**

Abra `lib/ravanshenasi/accounts/user.ex`. No bloco `schema "users" do`, adicione os campos; depois adicione a função `tenant_changeset/2`.

```elixir
# inside schema "users" do ... (after the existing fields)
field :name, :string
field :role, Ecto.Enum, values: [:admin, :therapist]
belongs_to :tenant, Ravanshenasi.Accounts.Tenant, type: :binary_id
```

```elixir
# new public function in the User module
@doc "Campos de tenant/perfil — usado no registro e aceite de convite."
def tenant_changeset(user, attrs) do
  user
  |> cast(attrs, [:tenant_id, :name, :role])
  |> validate_required([:tenant_id, :name, :role])
end
```

- [ ] **Step 5: Migrar e testar**

Run: `mix ecto.migrate && mix test test/ravanshenasi/accounts/user_tenant_fields_test.exs`
Expected: PASS (2 testes).

- [ ] **Step 6: Garantir suíte gerada ainda verde**

Run: `mix test`
Expected: alguns testes de fixtures do gerador podem falhar por `tenant_id`/`name`/`role` `null` agora obrigatórios. Se falharem, ajuste `test/support/fixtures/accounts_fixtures.ex` **na Task 10** (registro solo cria tenant). Por ora, anote os testes vermelhos; **não** commite quebrado — se houver falhas, vá pro Step 7 só após a Task 10. Se tudo verde, siga.

> Nota: como `tenant_id` virou `NOT NULL`, o caminho limpo é o fixture de user passar a usar `Accounts.register_solo/1` (Task 10). Recomendado: **parear** este Step 6 com a Task 10 antes de commitar a suíte inteira verde. O commit do Step 7 abaixo cobre só o schema + migration + teste-unidade deste task.

- [ ] **Step 7: Commit (schema + migration + teste-unidade)**

```bash
git add lib/ravanshenasi/accounts/user.ex priv/repo/migrations/*_add_tenant_fields_to_users.exs test/ravanshenasi/accounts/user_tenant_fields_test.exs
git commit -m "feat: adiciona tenant_id, role e name ao usuario"
```

---

## Task 4: Schema e migration de `invitations`

**Files:**
- Create: `lib/ravanshenasi/accounts/invitation.ex`
- Create: `priv/repo/migrations/<ts>_create_invitations.exs`
- Test: `test/ravanshenasi/accounts/invitation_test.exs`

- [ ] **Step 1: Escrever o teste (falha)**

```elixir
# test/ravanshenasi/accounts/invitation_test.exs
defmodule Ravanshenasi.Accounts.InvitationTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts.Invitation

  test "build/2 gera token cru + hash e expires_at futuro" do
    tenant_id = Ecto.UUID.generate()
    inviter_id = Ecto.UUID.generate()

    {raw_token, changeset} =
      Invitation.build(%{email: "novo@ex.com", role: :therapist}, tenant_id: tenant_id, invited_by_user_id: inviter_id)

    assert is_binary(raw_token) and byte_size(raw_token) > 20
    assert changeset.valid?
    assert get_field(changeset, :tenant_id) == tenant_id
    assert get_field(changeset, :token) != raw_token
    assert DateTime.compare(get_field(changeset, :expires_at), DateTime.utc_now()) == :gt
  end

  test "changeset exige email" do
    cs = Invitation.changeset(%Invitation{}, %{role: :therapist})
    refute cs.valid?
    assert %{email: ["can't be blank"]} = errors_on(cs)
  end
end
```

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi/accounts/invitation_test.exs`
Expected: FAIL — módulo `Invitation` indefinido.

- [ ] **Step 3: Criar a migration**

```elixir
# priv/repo/migrations/<ts>_create_invitations.exs
defmodule Ravanshenasi.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def change do
    create table(:invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :email, :citext, null: false
      add :role, :string, null: false
      add :token, :binary, null: false
      add :invited_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :accepted_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:tenant_id, :email])
    create unique_index(:invitations, [:token])
    create index(:invitations, [:tenant_id])
  end
end
```

- [ ] **Step 4: Criar o schema**

```elixir
# lib/ravanshenasi/accounts/invitation.ex
defmodule Ravanshenasi.Accounts.Invitation do
  use Ecto.Schema
  import Ecto.Changeset

  @token_bytes 32
  @ttl_days 7

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "invitations" do
    field :email, :string
    field :role, Ecto.Enum, values: [:therapist]
    field :token, :binary
    field :accepted_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :tenant, Ravanshenasi.Accounts.Tenant
    belongs_to :invited_by_user, Ravanshenasi.Accounts.User, foreign_key: :invited_by_user_id

    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :role])
    |> validate_required([:email, :role])
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+$/)
  end

  @doc """
  Monta uma invitation com token. Retorna `{raw_token, changeset}` —
  o token cru vai no link do email; só o hash é persistido.
  """
  def build(attrs, opts) do
    raw_token = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
    hashed = :crypto.hash(:sha256, raw_token)
    expires_at = DateTime.utc_now() |> DateTime.add(@ttl_days, :day) |> DateTime.truncate(:second)

    changeset =
      %__MODULE__{}
      |> changeset(attrs)
      |> put_change(:token, hashed)
      |> put_change(:tenant_id, opts[:tenant_id])
      |> put_change(:invited_by_user_id, opts[:invited_by_user_id])
      |> put_change(:expires_at, expires_at)

    {raw_token, changeset}
  end

  @doc "Hash de um token cru, pra lookup."
  def hash_token(raw_token), do: :crypto.hash(:sha256, raw_token)
end
```

- [ ] **Step 5: Migrar e testar**

Run: `mix ecto.migrate && mix test test/ravanshenasi/accounts/invitation_test.exs`
Expected: PASS (2 testes).

- [ ] **Step 6: Commit**

```bash
git add lib/ravanshenasi/accounts/invitation.ex priv/repo/migrations/*_create_invitations.exs test/ravanshenasi/accounts/invitation_test.exs
git commit -m "feat: schema e migration de invitations com token hasheado"
```

---

## Task 5: RLS forçado + guard de role do banco

**Files:**
- Create: `lib/ravanshenasi/rls.ex`
- Create: `priv/repo/migrations/<ts>_enable_tenant_rls.exs`
- Test: `test/ravanshenasi/rls_role_test.exs`

- [ ] **Step 1: Teste — a role da app não pode ter superuser/BYPASSRLS (falha)**

```elixir
# test/ravanshenasi/rls_role_test.exs
defmodule Ravanshenasi.RlsRoleTest do
  use Ravanshenasi.DataCase, async: true

  test "role de conexão da app não é superuser nem tem BYPASSRLS" do
    %{rows: [[is_super, is_bypass]]} =
      Ravanshenasi.Repo.query!(
        "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
      )

    assert is_super == false, "role da app é superuser — RLS seria ignorado"
    assert is_bypass == false, "role da app tem BYPASSRLS — RLS seria ignorado"
  end
end
```

- [ ] **Step 2: Rodar**

Run: `mix test test/ravanshenasi/rls_role_test.exs`
Expected: pode **FALHAR** se o `DATABASE_URL` de dev/test usar o superuser `postgres`. Se falhar, crie uma role comum no Step 3a antes de seguir.

- [ ] **Step 3a: (se falhou) Criar role da app sem privilégios**

Crie a role no Postgres e aponte dev/test pra ela. Documente em `config/dev.exs` e `config/test.exs` o `username`.

```bash
docker compose exec -T db psql -U postgres -c "CREATE ROLE ravanshenasi_app LOGIN PASSWORD 'ravanshenasi_app';"
docker compose exec -T db psql -U postgres -c "GRANT ALL ON DATABASE ravanshenasi_dev TO ravanshenasi_app;"
docker compose exec -T db psql -U postgres -c "GRANT ALL ON DATABASE ravanshenasi_test1 TO ravanshenasi_app;"
```

> Ajuste `config/dev.exs` e `config/test.exs` (`username: "ravanshenasi_app"`, `password: "ravanshenasi_app"`). A role **não** tem `SUPERUSER`/`BYPASSRLS` (default do `CREATE ROLE`). Garanta que ela tem `GRANT` nas tabelas: rode `mix ecto.reset` ou conceda `GRANT ALL ON ALL TABLES IN SCHEMA public`. Como migrations rodam como o owner, pode ser necessário `ALTER DEFAULT PRIVILEGES`. Mantenha simples: dê ownership do schema à role da app em dev/test.

- [ ] **Step 3b: Helper de RLS para migrations**

```elixir
# lib/ravanshenasi/rls.ex
defmodule Ravanshenasi.RLS do
  @moduledoc """
  Helper de migration: liga RLS fail-closed numa tabela.
  Policy compara `column` com o GUC `app.current_tenant_id`,
  com bypass explícito via `app.auth_bypass = 'on'`.
  """
  import Ecto.Migration

  def enable_tenant_rls(table, column \\ "tenant_id") do
    predicate = """
    #{column} = current_setting('app.current_tenant_id', true)::uuid
    OR current_setting('app.auth_bypass', true) = 'on'
    """

    execute(
      "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY",
      "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      "CREATE POLICY tenant_isolation ON #{table} USING (#{predicate}) WITH CHECK (#{predicate})",
      "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
    )
  end
end
```

- [ ] **Step 3c: Migration aplicando RLS**

```elixir
# priv/repo/migrations/<ts>_enable_tenant_rls.exs
defmodule Ravanshenasi.Repo.Migrations.EnableTenantRls do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    enable_tenant_rls("tenants", "id")
    enable_tenant_rls("users")
    enable_tenant_rls("invitations")
    # users_tokens stays outside tenant RLS (no tenant_id), protected by token + scope.
  end
end
```

- [ ] **Step 4: Migrar e rodar o guard**

Run: `mix ecto.migrate && mix test test/ravanshenasi/rls_role_test.exs`
Expected: PASS.

> **Esperado a partir daqui:** com RLS ligado em `users`, a suíte de auth **gerada** (login por email/token) fica **temporariamente vermelha** — os lookups pré-tenant ainda não foram blindados. Isso é corrigido na **Task 7b** (precisa dos helpers da Task 7 primeiro). Não rode `mix test` inteiro esperando verde entre a Task 5 e a 7b; rode só os arquivos-alvo de cada task.

- [ ] **Step 5: Commit**

```bash
git add lib/ravanshenasi/rls.ex priv/repo/migrations/*_enable_tenant_rls.exs test/ravanshenasi/rls_role_test.exs config/dev.exs config/test.exs
git commit -m "feat: RLS forcado em tenants/users/invitations + guard de role sem BYPASSRLS"
```

---

## Task 6: `Repo.transact_tenant/2`

**Files:**
- Modify: `lib/ravanshenasi/repo.ex`
- Test: `test/ravanshenasi/repo_transact_tenant_test.exs`

- [ ] **Step 1: Teste do contrato (falha)**

```elixir
# test/ravanshenasi/repo_transact_tenant_test.exs
defmodule Ravanshenasi.RepoTransactTenantTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Repo
  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Accounts.Tenant

  defp scope_for(tenant), do: %Scope{tenant: tenant}

  test "retorna o resultado CRU da função (não {:ok, _})" do
    tenant = %Tenant{id: Ecto.UUID.generate()}
    result = Repo.transact_tenant(scope_for(tenant), fn -> 42 end)
    assert result == 42
  end

  test "seta app.current_tenant_id dentro do bloco" do
    id = Ecto.UUID.generate()
    tenant = %Tenant{id: id}

    got =
      Repo.transact_tenant(scope_for(tenant), fn ->
        %{rows: [[v]]} = Repo.query!("SELECT current_setting('app.current_tenant_id', true)")
        v
      end)

    assert got == id
  end

  test "levanta com scope sem tenant" do
    assert_raise ArgumentError, fn ->
      Repo.transact_tenant(%Scope{tenant: nil}, fn -> :nope end)
    end
  end
end
```

> O `Scope` ainda não tem o campo `tenant` (Task 9). Para destravar este task, adicione **agora** o campo mínimo ao struct: abra `lib/ravanshenasi/accounts/scope.ex` e troque `defstruct user: nil` por `defstruct user: nil, tenant: nil`. A Task 9 completa o resto (helpers).

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi/repo_transact_tenant_test.exs`
Expected: FAIL — `transact_tenant/2 is undefined`.

- [ ] **Step 3: Implementar no Repo**

Abra `lib/ravanshenasi/repo.ex` e adicione (após o `use Ecto.Repo`):

```elixir
alias Ravanshenasi.Accounts.Scope

@doc """
Roda `fun` dentro de uma transação com `app.current_tenant_id` setado
(SET LOCAL) para o tenant do scope. Retorna o resultado CRU de `fun.()`
(não `{:ok, _}`). Levanta com scope sem tenant válido.
"""
def transact_tenant(%Scope{tenant: %{id: id}}, fun) when is_function(fun, 0) do
  {:ok, result} =
    transaction(fn ->
      set_local("app.current_tenant_id", id)
      fun.()
    end)

  result
end

def transact_tenant(%Scope{tenant: nil}, _fun) do
  raise ArgumentError, "transact_tenant requer um %Scope{} com tenant carregado"
end

# is_local = true -> applies only to the current transaction; in production the
# transaction is short (a single pool checkout), so the GUC never leaks between requests.
defp set_local(key, value) do
  query!("SELECT set_config($1, $2, true)", [key, to_string(value)])
end
```

- [ ] **Step 4: Rodar — deve passar**

Run: `mix test test/ravanshenasi/repo_transact_tenant_test.exs`
Expected: PASS (3 testes).

- [ ] **Step 5: Commit**

```bash
git add lib/ravanshenasi/repo.ex lib/ravanshenasi/accounts/scope.ex test/ravanshenasi/repo_transact_tenant_test.exs
git commit -m "feat: Repo.transact_tenant/2 com SET LOCAL e retorno cru"
```

---

## Task 7: `with_auth_bypass/1` e `with_registration_bypass/1`

**Files:**
- Modify: `lib/ravanshenasi/repo.ex`
- Test: `test/ravanshenasi/repo_bypass_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi/repo_bypass_test.exs
defmodule Ravanshenasi.RepoBypassTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Repo

  test "with_auth_bypass liga o GUC dentro e desliga depois" do
    inside =
      Repo.with_auth_bypass(fn ->
        %{rows: [[v]]} = Repo.query!("SELECT current_setting('app.auth_bypass', true)")
        v
      end)

    assert inside == "on"

    %{rows: [[after_val]]} = Repo.query!("SELECT current_setting('app.auth_bypass', true)")
    assert after_val in [nil, "", "off"]
  end

  test "with_registration_bypass também liga e devolve resultado cru" do
    assert Repo.with_registration_bypass(fn -> :done end) == :done
  end
end
```

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi/repo_bypass_test.exs`
Expected: FAIL — funções indefinidas.

- [ ] **Step 3: Implementar (mesmo GUC, nomes separados por auditoria)**

Adicione ao `lib/ravanshenasi/repo.ex`:

```elixir
@doc "Bypass de RLS para os 3 lookups pré-tenant (login por email, token de sessão, invitation por token)."
def with_auth_bypass(fun) when is_function(fun, 0), do: do_bypass(fun)

@doc "Bypass de RLS para criação pré-tenant (INSERT de tenant/user no registro e aceite)."
def with_registration_bypass(fun) when is_function(fun, 0), do: do_bypass(fun)

defp do_bypass(fun) do
  {:ok, result} =
    transaction(fn ->
      set_local("app.auth_bypass", "on")

      try do
        fun.()
      after
        # Explicit reset: under the Sandbox's long-running transaction (tests),
        # ensures the bypass does not leak into subsequent asserts. In production
        # this is redundant (the transaction closes right away), but harmless.
        set_local("app.auth_bypass", "off")
      end
    end)

  result
end
```

- [ ] **Step 4: Rodar — deve passar**

Run: `mix test test/ravanshenasi/repo_bypass_test.exs`
Expected: PASS (2 testes).

> Se `with_auth_bypass` retornar `"off"` no assert "inside", o reset do `after` está rodando cedo demais — confirme que está dentro do mesmo `transaction/1`. Se o assert "after" pegar `"on"`, o `after` não rodou: cheque que `fun.()` não escapou a transação.

- [ ] **Step 5: Commit**

```bash
git add lib/ravanshenasi/repo.ex test/ravanshenasi/repo_bypass_test.exs
git commit -m "feat: with_auth_bypass e with_registration_bypass (mesmo GUC, nomes por auditoria)"
```

---

## Task 7b: Blindar os lookups de auth gerados com `with_auth_bypass`

**Crítico.** Ao ligar RLS em `users` (Task 5), as funções de lookup geradas pelo `phx.gen.auth` (`get_user_by_email`, `get_user_by_session_token`, etc.) passam a rodar fail-closed **sem** GUC de tenant → retornam `nil` → **login e sessão quebram**. Estes são 2 dos 3 lookups pré-tenant do spec. Envolva-os em `with_auth_bypass/1`.

**Files:**
- Modify: `lib/ravanshenasi/accounts.ex` (funções de lookup de user geradas)
- Test: `test/ravanshenasi/accounts/auth_lookups_rls_test.exs`

- [ ] **Step 1: Teste — login por email funciona mesmo com RLS ligado (falha)**

```elixir
# test/ravanshenasi/accounts/auth_lookups_rls_test.exs
defmodule Ravanshenasi.Accounts.AuthLookupsRlsTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts

  test "get_user_by_email acha o user apesar do RLS forçado em users" do
    {:ok, user} = Accounts.register_solo(%{name: "Ana", email: "ana@ex.com", office_name: "C"})
    # no tenant in context: simulates login before the tenant is known
    assert %{id: id} = Accounts.get_user_by_email("ana@ex.com")
    assert id == user.id
  end
end
```

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi/accounts/auth_lookups_rls_test.exs`
Expected: FAIL — `get_user_by_email/1` retorna `nil` (RLS fail-closed em `users`).

- [ ] **Step 3: Envolver os lookups gerados em `with_auth_bypass`**

Abra `lib/ravanshenasi/accounts.ex` e localize as funções de lookup de user **geradas** que tocam a tabela `users` num contexto pré-tenant. Tipicamente: `get_user_by_email/1`, `get_user_by_email_and_password/2`, `get_user_by_session_token/1`, e a função do magic link (ex.: `get_user_by_magic_link_token/1` ou via `UserToken`). Envolva o corpo de cada uma em `Repo.with_auth_bypass(fn -> ... end)`.

Exemplo (adapte ao corpo real gerado):

```elixir
def get_user_by_email(email) when is_binary(email) do
  Repo.with_auth_bypass(fn -> Repo.get_by(User, email: email) end)
end

def get_user_by_session_token(token) do
  Repo.with_auth_bypass(fn ->
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end)
end
```

> Regra prática: **toda** função do `Accounts` que lê `users`/`users_tokens` para autenticar (antes de existir tenant) entra em `with_auth_bypass`. As demais funções (já com scope) usam `transact_tenant`. Audite com `grep -n "Repo\." lib/ravanshenasi/accounts.ex` e classifique cada lookup.

- [ ] **Step 4: Rodar alvo + suíte de auth gerada**

Run: `mix test test/ravanshenasi/accounts/auth_lookups_rls_test.exs && mix test test/ravanshenasi/accounts_test.exs`
Expected: PASS. A suíte de auth gerada (login magic link, senha, sessão) volta a verde com RLS ligado.

- [ ] **Step 5: Commit**

```bash
git add lib/ravanshenasi/accounts.ex test/ravanshenasi/accounts/auth_lookups_rls_test.exs
git commit -m "fix: blinda lookups de auth gerados com with_auth_bypass (RLS em users)"
```

---

## Task 8: Teste-âncora de isolamento (scope + RLS fail-closed)

Este é o teste que justifica a fundação. Usa `invitations` (tem `tenant_id`) como prova.

**Files:**
- Test: `test/ravanshenasi/tenant_isolation_test.exs`

- [ ] **Step 1: Escrever o teste-âncora (falha)**

```elixir
# test/ravanshenasi/tenant_isolation_test.exs
defmodule Ravanshenasi.TenantIsolationTest do
  use Ravanshenasi.DataCase, async: false

  alias Ravanshenasi.Repo
  alias Ravanshenasi.Accounts.{Scope, Tenant, Invitation}

  setup do
    {:ok, ta} = Repo.with_registration_bypass(fn -> Repo.insert(%Tenant{name: "A", plan: :clinic}) end)
    {:ok, tb} = Repo.with_registration_bypass(fn -> Repo.insert(%Tenant{name: "B", plan: :clinic}) end)

    insert_inv = fn tenant, email ->
      {_raw, cs} = Invitation.build(%{email: email, role: :therapist}, tenant_id: tenant.id, invited_by_user_id: nil)
      {:ok, inv} = Repo.with_registration_bypass(fn -> Repo.insert(cs) end)
      inv
    end

    insert_inv.(ta, "a1@ex.com")
    insert_inv.(tb, "b1@ex.com")

    %{tenant_a: ta, tenant_b: tb}
  end

  test "RLS: dentro de transact_tenant(A) só enxerga invitations do tenant A", %{tenant_a: ta} do
    emails =
      Repo.transact_tenant(%Scope{tenant: ta}, fn ->
        Repo.all(Invitation) |> Enum.map(& &1.email)
      end)

    assert emails == ["a1@ex.com"]
  end

  test "RLS fail-closed: sem GUC de tenant, query direta retorna 0 linhas" do
    # no active transact_tenant/bypass here -> app.current_tenant_id is NULL
    assert Repo.all(Invitation) == []
  end
end
```

> `async: false` e setup com bypass: como o GUC é `SET LOCAL` na transação do Sandbox, rode este arquivo isolado se necessário. O teste "fail-closed" depende de **nenhum** bypass/tenant ativo no início — por isso ele não chama `transact_tenant`/`with_*_bypass` antes do assert.

- [ ] **Step 2: Rodar**

Run: `mix test test/ravanshenasi/tenant_isolation_test.exs`
Expected: PASS (2 testes). Se "fail-closed" pegar linhas, o `after`-reset do bypass (Task 7) não está revertendo o GUC sob Sandbox — investigue com `Repo.query!("SELECT current_setting('app.auth_bypass', true), current_setting('app.current_tenant_id', true)")` no início do teste; ambos devem ser vazios.

- [ ] **Step 3: Commit**

```bash
git add test/ravanshenasi/tenant_isolation_test.exs
git commit -m "test: teste-ancora de isolamento (scope + RLS fail-closed)"
```

---

## Task 9: Estender `Scope` e injetar `tenant` no `current_scope`

**Files:**
- Modify: `lib/ravanshenasi/accounts/scope.ex`
- Modify: `lib/ravanshenasi_web/user_auth.ex`
- Modify: `lib/ravanshenasi/accounts.ex` (helper `get_tenant!/1`)
- Test: `test/ravanshenasi/accounts/scope_test.exs`

- [ ] **Step 1: Teste do Scope (falha)**

```elixir
# test/ravanshenasi/accounts/scope_test.exs
defmodule Ravanshenasi.Accounts.ScopeTest do
  use ExUnit.Case, async: true

  alias Ravanshenasi.Accounts.{Scope, User, Tenant}

  test "put_tenant + admin?/therapist?" do
    user = %User{role: :admin}
    tenant = %Tenant{id: Ecto.UUID.generate()}

    scope = Scope.for_user(user) |> Scope.put_tenant(tenant)

    assert scope.tenant == tenant
    assert Scope.admin?(scope)
    refute Scope.therapist?(scope)
  end

  test "therapist?" do
    scope = Scope.for_user(%User{role: :therapist})
    assert Scope.therapist?(scope)
    refute Scope.admin?(scope)
  end
end
```

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi/accounts/scope_test.exs`
Expected: FAIL — `put_tenant/2` indefinido.

- [ ] **Step 3: Estender o Scope**

Abra `lib/ravanshenasi/accounts/scope.ex`. O struct já tem `tenant: nil` (Task 6). Adicione os helpers (o `for_user/1` gerado já existe — não duplique):

```elixir
alias Ravanshenasi.Accounts.Tenant

def put_tenant(%__MODULE__{} = scope, %Tenant{} = tenant) do
  %{scope | tenant: tenant}
end

def admin?(%__MODULE__{user: %{role: :admin}}), do: true
def admin?(_), do: false

def therapist?(%__MODULE__{user: %{role: :therapist}}), do: true
def therapist?(_), do: false
```

- [ ] **Step 4: Helper `get_tenant!/1` no Accounts**

Adicione em `lib/ravanshenasi/accounts.ex`:

```elixir
alias Ravanshenasi.Accounts.Tenant

@doc "Carrega o tenant por id (lookup pré/peri-auth — sem RLS de tenant via bypass)."
def get_tenant!(id) do
  Repo.with_auth_bypass(fn -> Repo.get!(Tenant, id) end)
end
```

- [ ] **Step 5: Injetar tenant no scope ao autenticar**

Abra `lib/ravanshenasi_web/user_auth.ex`. Localize a função que monta o `current_scope` a partir do user (algo como `Scope.for_user(user)` dentro de `fetch_current_scope_for_user` e do `on_mount` de mount de scope). Onde o scope do user é criado, **encadeie o tenant**. Crie um helper privado e use-o nos dois pontos (plug e on_mount):

```elixir
# helper privado no UserAuth
defp with_tenant(nil), do: nil

defp with_tenant(%Ravanshenasi.Accounts.Scope{user: %{tenant_id: tenant_id}} = scope) do
  Ravanshenasi.Accounts.Scope.put_tenant(scope, Ravanshenasi.Accounts.get_tenant!(tenant_id))
end
```

Aplique envolvendo as chamadas existentes: onde houver `Scope.for_user(user)`, troque por `Scope.for_user(user) |> with_tenant()`.

- [ ] **Step 6: Rodar testes-alvo + suíte**

Run: `mix test test/ravanshenasi/accounts/scope_test.exs && mix test`
Expected: scope_test PASS. A suíte completa pode ainda ter vermelhos de fixtures (resolvidos na Task 10) — anote.

- [ ] **Step 7: Commit**

```bash
git add lib/ravanshenasi/accounts/scope.ex lib/ravanshenasi_web/user_auth.ex lib/ravanshenasi/accounts.ex test/ravanshenasi/accounts/scope_test.exs
git commit -m "feat: Scope com tenant + role helpers e injecao no current_scope"
```

---

## Task 10: `Accounts.register_solo/1`

**Files:**
- Modify: `lib/ravanshenasi/accounts.ex`
- Modify: `test/support/fixtures/accounts_fixtures.ex`
- Test: `test/ravanshenasi/accounts/register_solo_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi/accounts/register_solo_test.exs
defmodule Ravanshenasi.Accounts.RegisterSoloTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts
  alias Ravanshenasi.Accounts.{User, Tenant}

  test "cria tenant solo + user admin atomicamente" do
    attrs = %{
      name: "Dra. Ana",
      email: "ana@ex.com",
      office_name: "Consultório Ana"
    }

    assert {:ok, %User{} = user} = Accounts.register_solo(attrs)
    assert user.role == :admin
    assert user.name == "Dra. Ana"

    tenant = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.get!(Tenant, user.tenant_id) end)
    assert tenant.plan == :solo
    assert tenant.name == "Consultório Ana"
  end

  test "email duplicado falha" do
    attrs = %{name: "A", email: "dup@ex.com", office_name: "C"}
    assert {:ok, _} = Accounts.register_solo(attrs)
    assert {:error, _} = Accounts.register_solo(%{attrs | name: "B"})
  end
end
```

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi/accounts/register_solo_test.exs`
Expected: FAIL — `register_solo/1` indefinido.

- [ ] **Step 3: Implementar com `Ecto.Multi` sob bypass de registro**

Adicione em `lib/ravanshenasi/accounts.ex` (confirme os nomes das funções geradas de registro de user — provavelmente `User.email_changeset/2`; ajuste se diferir):

```elixir
alias Ecto.Multi
alias Ravanshenasi.Accounts.{Tenant, User}

@doc "Registra um profissional solo: cria tenant(plan: solo) + user(role: admin)."
def register_solo(attrs) do
  multi =
    Multi.new()
    |> Multi.insert(:tenant, Tenant.changeset(%Tenant{}, %{name: attrs.office_name, plan: :solo}))
    |> Multi.insert(:user, fn %{tenant: tenant} ->
      %User{}
      |> User.email_changeset(%{email: attrs.email})
      |> User.tenant_changeset(%{tenant_id: tenant.id, name: attrs.name, role: :admin})
    end)

  case Repo.with_registration_bypass(fn -> Repo.transaction(multi) end) do
    {:ok, %{user: user}} -> {:ok, user}
    {:error, _step, changeset, _} -> {:error, changeset}
  end
end
```

> `User.email_changeset/2` + `User.tenant_changeset/2` aplicados em sequência: confirme no `user.ex` gerado o nome do changeset de email (pode ser `email_changeset` ou via `registration_changeset`). Se o gerador usar `registration_changeset/2`, troque a 1ª por ela e mescle os campos. O importante: o user nasce com email + tenant_id + name + role, **sem** senha (magic-link-first).

- [ ] **Step 4: Atualizar o fixture de user**

Abra `test/support/fixtures/accounts_fixtures.ex`. Faça o `user_fixture/1` passar por `register_solo` (ou criar tenant + setar role/name) pra satisfazer os `NOT NULL`. Exemplo mínimo:

```elixir
def user_fixture(attrs \\ %{}) do
  email = Map.get(attrs, :email, "user#{System.unique_integer()}@ex.com")
  {:ok, user} = Ravanshenasi.Accounts.register_solo(%{name: "User", email: email, office_name: "Office"})
  user
end
```

> Ajuste outras funções do fixture (ex.: `unconfirmed_user_fixture`) que insiram user direto — todas precisam de tenant/role/name agora.

- [ ] **Step 5: Rodar alvo + suíte inteira**

Run: `mix test test/ravanshenasi/accounts/register_solo_test.exs && mix test`
Expected: register_solo PASS; **suíte inteira verde** (fixtures resolvidos). Se ainda houver vermelhos do gerador, ajuste o fixture correspondente.

- [ ] **Step 6: Commit**

```bash
git add lib/ravanshenasi/accounts.ex test/support/fixtures/accounts_fixtures.ex test/ravanshenasi/accounts/register_solo_test.exs
git commit -m "feat: Accounts.register_solo cria tenant solo + user admin"
```

---

## Task 11: `Accounts.register_clinic/1`

**Files:**
- Modify: `lib/ravanshenasi/accounts.ex`
- Test: `test/ravanshenasi/accounts/register_clinic_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi/accounts/register_clinic_test.exs
defmodule Ravanshenasi.Accounts.RegisterClinicTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts
  alias Ravanshenasi.Accounts.{User, Tenant}

  test "cria tenant clinic + user admin (gestor)" do
    attrs = %{clinic_name: "Clínica Z", name: "Admin Z", email: "admin@z.com"}

    assert {:ok, %User{} = user} = Accounts.register_clinic(attrs)
    assert user.role == :admin

    tenant = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.get!(Tenant, user.tenant_id) end)
    assert tenant.plan == :clinic
    assert tenant.name == "Clínica Z"
  end
end
```

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi/accounts/register_clinic_test.exs`
Expected: FAIL — `register_clinic/1` indefinido.

- [ ] **Step 3: Implementar (espelha register_solo, plan: clinic)**

```elixir
# lib/ravanshenasi/accounts.ex
@doc "Registra uma clínica: cria tenant(plan: clinic) + user(role: admin gestor)."
def register_clinic(attrs) do
  multi =
    Multi.new()
    |> Multi.insert(:tenant, Tenant.changeset(%Tenant{}, %{name: attrs.clinic_name, plan: :clinic}))
    |> Multi.insert(:user, fn %{tenant: tenant} ->
      %User{}
      |> User.email_changeset(%{email: attrs.email})
      |> User.tenant_changeset(%{tenant_id: tenant.id, name: attrs.name, role: :admin})
    end)

  case Repo.with_registration_bypass(fn -> Repo.transaction(multi) end) do
    {:ok, %{user: user}} -> {:ok, user}
    {:error, _step, changeset, _} -> {:error, changeset}
  end
end
```

> Há duplicação entre `register_solo` e `register_clinic`. Refatore extraindo um privado `do_register(tenant_attrs, user_attrs)` se preferir DRY — mas só após ambos verdes.

- [ ] **Step 4: Rodar — deve passar**

Run: `mix test test/ravanshenasi/accounts/register_clinic_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ravanshenasi/accounts.ex test/ravanshenasi/accounts/register_clinic_test.exs
git commit -m "feat: Accounts.register_clinic cria tenant clinic + user admin gestor"
```

---

## Task 12: Convites — criar, buscar por token, aceitar

**Files:**
- Modify: `lib/ravanshenasi/accounts.ex`
- Modify: `lib/ravanshenasi/accounts/user_notifier.ex` (email de convite)
- Test: `test/ravanshenasi/accounts/invitations_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi/accounts/invitations_test.exs
defmodule Ravanshenasi.Accounts.InvitationsTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts
  alias Ravanshenasi.Accounts.{Scope, User}

  setup do
    {:ok, admin} = Accounts.register_clinic(%{clinic_name: "C", name: "Admin", email: "admin@c.com"})
    admin = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.preload(admin, :tenant) end)
    %{admin: admin, scope: Scope.for_user(admin) |> Scope.put_tenant(admin.tenant)}
  end

  test "create_invitation gera token e o aceite cria therapist no tenant certo", %{admin: admin, scope: scope} do
    assert {:ok, raw_token} = Accounts.create_invitation(scope, %{email: "novo@c.com", role: :therapist})

    assert {:ok, %User{} = member} =
             Accounts.accept_invitation(raw_token, %{name: "Novo", password: "supersecret123"})

    assert member.role == :therapist
    assert member.tenant_id == admin.tenant_id
    assert member.email == "novo@c.com"
  end

  test "token inválido falha", %{} do
    assert {:error, :invalid_invitation} = Accounts.accept_invitation("naoexiste", %{name: "X"})
  end

  test "convite expirado falha", %{scope: scope} do
    {:ok, raw} = Accounts.create_invitation(scope, %{email: "exp@c.com", role: :therapist})
    # force expiration
    Ravanshenasi.Repo.with_auth_bypass(fn ->
      Ravanshenasi.Repo.update_all(Ravanshenasi.Accounts.Invitation, set: [expires_at: ~U[2000-01-01 00:00:00Z]])
    end)

    assert {:error, :expired} = Accounts.accept_invitation(raw, %{name: "X", password: "supersecret123"})
  end
end
```

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi/accounts/invitations_test.exs`
Expected: FAIL — funções de convite indefinidas.

- [ ] **Step 3: Implementar no Accounts**

```elixir
# lib/ravanshenasi/accounts.ex
alias Ravanshenasi.Accounts.Invitation

@doc "Admin cria um convite no seu tenant. Retorna {:ok, raw_token}."
def create_invitation(%Scope{} = scope, attrs) do
  true = Scope.admin?(scope)

  {raw_token, changeset} =
    Invitation.build(attrs, tenant_id: scope.tenant.id, invited_by_user_id: scope.user.id)

  case transact_tenant(scope, fn -> Repo.insert(changeset) end) do
    {:ok, invitation} ->
      deliver_invitation_email(invitation, scope.tenant, raw_token)
      {:ok, raw_token}

    {:error, changeset} ->
      {:error, changeset}
  end
end

@doc "Aceita um convite por token cru: cria user(role) no tenant e marca accepted_at."
def accept_invitation(raw_token, attrs) do
  hashed = Invitation.hash_token(raw_token)

  invitation =
    Repo.with_auth_bypass(fn -> Repo.get_by(Invitation, token: hashed) end)

  cond do
    is_nil(invitation) ->
      {:error, :invalid_invitation}

    not is_nil(invitation.accepted_at) ->
      {:error, :already_accepted}

    DateTime.compare(invitation.expires_at, DateTime.utc_now()) != :gt ->
      {:error, :expired}

    true ->
      do_accept_invitation(invitation, attrs)
  end
end

defp do_accept_invitation(invitation, attrs) do
  multi =
    Multi.new()
    |> Multi.insert(:user, fn _ ->
      %User{}
      |> User.email_changeset(%{email: invitation.email})
      |> maybe_put_password(attrs[:password])
      |> User.tenant_changeset(%{tenant_id: invitation.tenant_id, name: attrs.name, role: invitation.role})
    end)
    |> Multi.update(:invitation, Invitation.changeset(invitation, %{}) |> Ecto.Changeset.put_change(:accepted_at, DateTime.utc_now() |> DateTime.truncate(:second)))

  case Repo.with_registration_bypass(fn -> Repo.transaction(multi) end) do
    {:ok, %{user: user}} -> {:ok, user}
    {:error, _step, changeset, _} -> {:error, changeset}
  end
end

defp maybe_put_password(changeset, nil), do: changeset
defp maybe_put_password(changeset, password), do: User.password_changeset(changeset, %{password: password})
```

> Confirme no `user.ex` gerado o nome do changeset de senha (provável `password_changeset/2` ou `/3` com opções). Ajuste `maybe_put_password`. O aceite usa `with_registration_bypass` porque o `accepted_at` marca uma invitation cujo tenant ainda não está no scope do convidado.

- [ ] **Step 4: Email de convite**

Em `lib/ravanshenasi/accounts/user_notifier.ex`, adicione um `deliver_invitation_email/3` espelhando os notifiers gerados (mesmo padrão de `deliver/3` + `Swoosh`). E no `Accounts`, o privado:

```elixir
# lib/ravanshenasi/accounts.ex
defp deliver_invitation_email(invitation, tenant, raw_token) do
  url = RavanshenasiWeb.Endpoint.url() <> "/convites/#{raw_token}"
  Ravanshenasi.Accounts.UserNotifier.deliver_invitation(invitation.email, tenant.name, url)
end
```

```elixir
# lib/ravanshenasi/accounts/user_notifier.ex (follows the generated deliver_* pattern)
def deliver_invitation(email, tenant_name, url) do
  deliver(email, "Convite para #{tenant_name}", """

  Você foi convidado(a) para a equipe de #{tenant_name} no PsiCare.

  Aceite seu convite em:

  #{url}

  Se você não esperava este convite, ignore este email.
  """)
end
```

- [ ] **Step 5: Rodar — deve passar**

Run: `mix test test/ravanshenasi/accounts/invitations_test.exs`
Expected: PASS (3 testes).

- [ ] **Step 6: Commit**

```bash
git add lib/ravanshenasi/accounts.ex lib/ravanshenasi/accounts/user_notifier.ex test/ravanshenasi/accounts/invitations_test.exs
git commit -m "feat: convites de membro (criar, aceitar por token, email)"
```

---

## Task 13: Autorização — `require_admin` (on_mount + plug)

**Files:**
- Modify: `lib/ravanshenasi_web/user_auth.ex`
- Test: `test/ravanshenasi_web/user_auth_admin_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi_web/user_auth_admin_test.exs
defmodule RavanshenasiWeb.UserAuthAdminTest do
  use RavanshenasiWeb.ConnCase, async: true

  alias RavanshenasiWeb.UserAuth
  alias Ravanshenasi.Accounts.Scope

  test "require_admin deixa passar admin", %{conn: conn} do
    {:ok, admin} = Ravanshenasi.Accounts.register_clinic(%{clinic_name: "C", name: "A", email: "a@c.com"})
    admin = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.preload(admin, :tenant) end)
    scope = Scope.for_user(admin) |> Scope.put_tenant(admin.tenant)

    conn = conn |> Plug.Conn.assign(:current_scope, scope) |> UserAuth.require_admin([])
    refute conn.halted
  end

  test "require_admin barra therapist", %{conn: conn} do
    scope = Scope.for_user(%Ravanshenasi.Accounts.User{role: :therapist})
    conn = conn |> Plug.Conn.assign(:current_scope, scope) |> UserAuth.require_admin([])
    assert conn.halted
  end
end
```

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi_web/user_auth_admin_test.exs`
Expected: FAIL — `require_admin/2` indefinido.

- [ ] **Step 3: Implementar no UserAuth**

Adicione em `lib/ravanshenasi_web/user_auth.ex` (o plug; e um `on_mount` equivalente pras LiveViews):

```elixir
@doc "Plug: exige role admin no current_scope."
def require_admin(conn, _opts) do
  if Ravanshenasi.Accounts.Scope.admin?(conn.assigns[:current_scope]) do
    conn
  else
    conn
    |> Phoenix.Controller.put_flash(:error, "Acesso restrito ao administrador.")
    |> Phoenix.Controller.redirect(to: ~p"/")
    |> halt()
  end
end

@doc "on_mount: exige admin nas LiveViews de gestão."
def on_mount(:require_admin, _params, _session, socket) do
  if Ravanshenasi.Accounts.Scope.admin?(socket.assigns[:current_scope]) do
    {:cont, socket}
  else
    {:halt, socket |> Phoenix.LiveView.put_flash(:error, "Acesso restrito ao administrador.") |> Phoenix.LiveView.redirect(to: ~p"/")}
  end
end
```

> Garanta os imports/aliases no topo do módulo (`import Plug.Conn` já existe no arquivo gerado; `~p` vem de `use RavanshenasiWeb, :verified_routes` — confirme que o módulo gerado já usa).

- [ ] **Step 4: Rodar — deve passar**

Run: `mix test test/ravanshenasi_web/user_auth_admin_test.exs`
Expected: PASS (2 testes).

- [ ] **Step 5: Commit**

```bash
git add lib/ravanshenasi_web/user_auth.ex test/ravanshenasi_web/user_auth_admin_test.exs
git commit -m "feat: autorizacao require_admin (plug + on_mount)"
```

---

## Task 14: LiveViews de onboarding e gestão

Reusa os componentes gerados (`<.input>`, `<.button>`, `core_components`). Foco em testes de integração com `Phoenix.LiveViewTest`.

**Files:**
- Create: `lib/ravanshenasi_web/live/org/registration_live.ex` (registro de clínica)
- Create: `lib/ravanshenasi_web/live/org/members_live.ex` (lista membros + cria convite)
- Create: `lib/ravanshenasi_web/live/org/accept_invitation_live.ex` (aceite por token)
- Modify: `lib/ravanshenasi_web/router.ex`
- Test: `test/ravanshenasi_web/live/org_flows_test.exs`

- [ ] **Step 1: Teste de integração (falha)**

```elixir
# test/ravanshenasi_web/live/org_flows_test.exs
defmodule RavanshenasiWeb.OrgFlowsTest do
  use RavanshenasiWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "registro de clínica cria conta admin", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/registrar/clinica")

    form = %{"clinic" => %{"clinic_name" => "Clínica Y", "name" => "Dona Y", "email" => "dona@y.com"}}

    lv
    |> form("#clinic-registration-form", form)
    |> render_submit()

    assert Ravanshenasi.Repo.with_auth_bypass(fn ->
             Ravanshenasi.Repo.get_by(Ravanshenasi.Accounts.User, email: "dona@y.com")
           end)
  end

  test "admin convida e membro aceita", %{conn: conn} do
    {:ok, admin} = Ravanshenasi.Accounts.register_clinic(%{clinic_name: "C", name: "A", email: "admin@c.com"})
    admin = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.preload(admin, :tenant) end)
    scope = Ravanshenasi.Accounts.Scope.for_user(admin) |> Ravanshenasi.Accounts.Scope.put_tenant(admin.tenant)

    {:ok, raw} = Ravanshenasi.Accounts.create_invitation(scope, %{email: "membro@c.com", role: :therapist})

    {:ok, lv, _html} = live(conn, ~p"/convites/#{raw}")

    lv
    |> form("#accept-invitation-form", %{"user" => %{"name" => "Membro", "password" => "supersecret123"}})
    |> render_submit()

    member = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.get_by(Ravanshenasi.Accounts.User, email: "membro@c.com") end)
    assert member.role == :therapist
  end
end
```

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi_web/live/org_flows_test.exs`
Expected: FAIL — rotas/LiveViews inexistentes.

- [ ] **Step 3: Rotas**

Em `lib/ravanshenasi_web/router.ex`, dentro do escopo público (sem auth) adicione registro de clínica e aceite; e um escopo autenticado+admin pra membros. Use os `live_session` gerados como modelo:

```elixir
# public scope (same live_session as generated registrations), inside `scope "/", RavanshenasiWeb`
live "/registrar/clinica", Org.RegistrationLive, :new
live "/convites/:token", Org.AcceptInvitationLive, :new

# authenticated + admin scope
live_session :require_admin,
  on_mount: [{RavanshenasiWeb.UserAuth, :require_authenticated}, {RavanshenasiWeb.UserAuth, :require_admin}] do
  live "/equipe", Org.MembersLive, :index
end
```

> Confirme o alias do namespace de LiveViews do projeto (o gerado usa `RavanshenasiWeb.UserLive.*`). Use o mesmo padrão de módulo: `RavanshenasiWeb.Org.RegistrationLive` etc., e ajuste os caminhos de `Create:` acima conforme o padrão real. Confirme o nome exato do `on_mount` `:require_authenticated` no `user_auth.ex` gerado (Step 5 da Task 1).

- [ ] **Step 4: LiveView de registro de clínica**

```elixir
# lib/ravanshenasi_web/live/org/registration_live.ex
defmodule RavanshenasiWeb.Org.RegistrationLive do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Accounts

  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{"clinic_name" => "", "name" => "", "email" => ""}, as: :clinic))}
  end

  def handle_event("save", %{"clinic" => params}, socket) do
    attrs = %{clinic_name: params["clinic_name"], name: params["name"], email: params["email"]}

    case Accounts.register_clinic(attrs) do
      {:ok, _user} ->
        {:noreply, socket |> put_flash(:info, "Clínica criada. Confira seu email para confirmar.") |> redirect(to: ~p"/users/log-in")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Não foi possível registrar. Verifique os dados.")}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header>Registrar clínica</.header>
      <.form for={@form} id="clinic-registration-form" phx-submit="save">
        <.input field={@form[:clinic_name]} label="Nome da clínica" required />
        <.input field={@form[:name]} label="Seu nome" required />
        <.input field={@form[:email]} type="email" label="Email" required />
        <.button phx-disable-with="Criando..." class="w-full">Criar clínica</.button>
      </.form>
    </div>
    """
  end
end
```

> O redirect `~p"/users/log-in"` deve bater com a rota de login gerada — confirme (pode ser `/users/log_in`). Como é magic-link-first, o admin confirma por email; ajuste o flash conforme o fluxo gerado.

- [ ] **Step 5: LiveView de aceite de convite**

```elixir
# lib/ravanshenasi_web/live/org/accept_invitation_live.ex
defmodule RavanshenasiWeb.Org.AcceptInvitationLive do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Accounts

  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     assign(socket,
       token: token,
       form: to_form(%{"name" => "", "password" => ""}, as: :user)
     )}
  end

  def handle_event("accept", %{"user" => params}, socket) do
    attrs = %{name: params["name"], password: params["password"]}

    case Accounts.accept_invitation(socket.assigns.token, attrs) do
      {:ok, _user} ->
        {:noreply, socket |> put_flash(:info, "Bem-vindo(a) à equipe!") |> redirect(to: ~p"/users/log-in")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, accept_error(reason))}
    end
  end

  defp accept_error(:invalid_invitation), do: "Convite inválido."
  defp accept_error(:expired), do: "Convite expirado."
  defp accept_error(:already_accepted), do: "Convite já utilizado."
  defp accept_error(_), do: "Não foi possível aceitar o convite."

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header>Aceitar convite</.header>
      <.form for={@form} id="accept-invitation-form" phx-submit="accept">
        <.input field={@form[:name]} label="Seu nome" required />
        <.input field={@form[:password]} type="password" label="Senha (opcional)" />
        <.button phx-disable-with="Entrando..." class="w-full">Entrar na equipe</.button>
      </.form>
    </div>
    """
  end
end
```

- [ ] **Step 6: LiveView de membros + convite**

```elixir
# lib/ravanshenasi_web/live/org/members_live.ex
defmodule RavanshenasiWeb.Org.MembersLive do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.Accounts

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       members: Accounts.list_members(socket.assigns.current_scope),
       form: to_form(%{"email" => ""}, as: :invitation)
     )}
  end

  def handle_event("invite", %{"invitation" => %{"email" => email}}, socket) do
    case Accounts.create_invitation(socket.assigns.current_scope, %{email: email, role: :therapist}) do
      {:ok, _raw} -> {:noreply, put_flash(socket, :info, "Convite enviado para #{email}.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Não foi possível convidar.")}
    end
  end

  def render(assigns) do
    ~H"""
    <.header>Equipe</.header>
    <.form for={@form} id="invite-form" phx-submit="invite">
      <.input field={@form[:email]} type="email" label="Convidar por email" required />
      <.button>Convidar therapist</.button>
    </.form>
    <ul>
      <li :for={m <- @members}>{m.name} — {m.email} ({m.role})</li>
    </ul>
    """
  end
end
```

- [ ] **Step 7: `list_members/1` no Accounts**

```elixir
# lib/ravanshenasi/accounts.ex
@doc "Lista usuários do tenant (gestão — só metadados, não dado clínico)."
def list_members(%Scope{} = scope) do
  transact_tenant(scope, fn ->
    Repo.all(from u in User, where: u.tenant_id == ^scope.tenant.id, order_by: u.name)
  end)
end
```

> Adicione `import Ecto.Query` no topo do `accounts.ex` se ainda não houver.

- [ ] **Step 8: Rodar — deve passar**

Run: `mix test test/ravanshenasi_web/live/org_flows_test.exs`
Expected: PASS (2 testes). Ajuste seletores/rotas conforme os nomes reais confirmados.

- [ ] **Step 9: Commit**

```bash
git add lib/ravanshenasi_web/live/org/ lib/ravanshenasi_web/router.ex lib/ravanshenasi/accounts.ex test/ravanshenasi_web/live/org_flows_test.exs
git commit -m "feat: LiveViews de registro de clinica, convites e equipe"
```

---

## Task 15: Registro solo na UI + fechamento

**Files:**
- Modify: `lib/ravanshenasi_web/live/user_live/registration.ex` (campo `office_name`) — confirme o caminho gerado.
- Test: `test/ravanshenasi_web/live/solo_registration_test.exs`

- [ ] **Step 1: Teste (falha)**

```elixir
# test/ravanshenasi_web/live/solo_registration_test.exs
defmodule RavanshenasiWeb.SoloRegistrationTest do
  use RavanshenasiWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "registro solo cria tenant + admin", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/register")

    lv
    |> form("#registration_form", %{"user" => %{"name" => "Dr. Solo", "email" => "solo@ex.com", "office_name" => "Consultório Solo"}})
    |> render_submit()

    user = Ravanshenasi.Repo.with_auth_bypass(fn -> Ravanshenasi.Repo.get_by(Ravanshenasi.Accounts.User, email: "solo@ex.com") end)
    assert user.role == :admin
  end
end
```

> Confirme a rota de registro gerada (`/users/register` vs `/users/log-in` com toggle). Ajuste `~p` e o `id` do form conforme o gerado.

- [ ] **Step 2: Rodar — deve falhar**

Run: `mix test test/ravanshenasi_web/live/solo_registration_test.exs`
Expected: FAIL.

- [ ] **Step 3: Adaptar o registro gerado pra solo**

Abra a LiveView de registro gerada. Adicione os campos `name` e `office_name` ao form e troque a chamada de criação de user pelo `Accounts.register_solo/1` (mapeando os params). Mantenha o fluxo de confirmação por email gerado.

```elixir
# no handle_event de submit do registro
attrs = %{name: params["name"], email: params["email"], office_name: params["office_name"]}

case Accounts.register_solo(attrs) do
  {:ok, user} ->
    # reuses the generated confirmation deliver (for example, Accounts.deliver_login_instructions/2)
    {:noreply, socket |> put_flash(:info, "Conta criada. Confira seu email.") |> ...}
  {:error, _changeset} ->
    {:noreply, ...}
end
```

> Adicione `<.input field={@form[:name]} label="Seu nome" />` e `<.input field={@form[:office_name]} label="Nome do consultório" />` ao HEEX. Confirme o nome do deliver de confirmação gerado.

- [ ] **Step 4: Rodar — deve passar**

Run: `mix test test/ravanshenasi_web/live/solo_registration_test.exs`
Expected: PASS.

- [ ] **Step 5: Suíte completa + precommit**

Run: `mix precommit`
Expected: compile sem warnings, `mix format --check-formatted` ok, **Credo `--strict` 0 issues**, **todos os testes verdes**.

> Se o Credo apontar nesting/alias nos novos módulos, ajuste (alias no topo, funções nomeadas). Não desabilite checks.

- [ ] **Step 6: Commit final da fatia**

```bash
git add -A
git commit -m "feat: registro solo na UI + fundacao (Fatia 0) completa"
```

---

## Definition of Done (verificação final contra o spec)

- [ ] Migrations criam `tenants`, `users` (+auth), `invitations`; RLS forçado em `tenants`(id), `users`, `invitations`; `users_tokens` fora do RLS-por-tenant. *(Tasks 2–5)*
- [ ] Registro solo e clínica ponta a ponta, com confirmação por email. *(Tasks 10, 11, 14, 15)*
- [ ] Admin de clínica convida therapist; convidado aceita e entra no tenant certo. *(Tasks 12, 14)*
- [ ] Login magic link **e** senha funcionam; sudo mode protege ações sensíveis. *(Task 1, base gerada)*
- [ ] **Teste-âncora de isolamento passa** (scope + RLS fail-closed). *(Task 8)*
- [ ] `transact_tenant/2`: sempre tx + `SET LOCAL`, retorno cru, levanta sem tenant. *(Task 6)*
- [ ] `with_auth_bypass` (3 lookups) e `with_registration_bypass` (criações) separados e auditáveis. *(Tasks 7, 10–12)*
- [ ] Lookups de auth gerados (login por email, token de sessão) blindados com `with_auth_bypass` — login funciona com RLS ligado em `users`. *(Task 7b)*
- [ ] Teste afirma role DB sem superuser/`BYPASSRLS`. *(Task 5)*
- [ ] `mix precommit` verde. *(Task 15)*

---

## Notas de risco para o executor

1. **`phx.gen.auth` 1.8 — nomes internos:** os changesets (`email_changeset`, `password_changeset`, `registration_changeset`) e os `on_mount` (`:require_authenticated`, `:mount_current_scope`) variam por patch. Sempre confirme no arquivo gerado (Task 1, Step 5) antes de estender. O plano dá o alvo; o nome exato vem do código.
2. **Sandbox + `SET LOCAL`:** o GUC é local à transação. Sob `Ecto.Adapters.SQL.Sandbox` (uma transação por teste), os helpers resetam o GUC no `after` (Task 7) pra não vazar entre asserts. Se algum teste de isolamento ficar instável, rode-o com `async: false` e cheque o GUC no início (Task 8, Step 2).
3. **Role do banco:** se dev/test rodam como `postgres` (superuser), o RLS é **silenciosamente ignorado**. A Task 5 cria uma role comum e o guard-test falha cedo se isso regredir. Não pule.
4. **Ordem de migrations:** `citext` vem da migration de auth (Task 1); `invitations` (Task 4) depende dela. Mantenha a ordem por timestamp.
