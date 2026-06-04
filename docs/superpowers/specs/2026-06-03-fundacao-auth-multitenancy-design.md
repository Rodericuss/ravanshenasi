# Fatia 0 — Fundação: Auth + Multi-tenancy (RLS)

**Projeto:** Ravanshenasi (PsiCare) — SaaS de psicologia
**Data:** 2026-06-03
**Status:** ✅ Implementado (Fatia 0 concluída, `mix precommit` verde). Ver **Adendo de implementação** abaixo.
**Stack:** Phoenix 1.8.7 + LiveView 1.1 + Ecto + TimescaleDB HA pg17 + Swoosh

---

## Adendo de implementação (decisões tomadas durante a execução)

Duas decisões mudaram o desenho original deste spec durante a implementação — ambas conscientes e validadas:

1. **RLS forçado apenas em `invitations` (não em `users`/`tenants`).** Forçar RLS em `users` obrigaria ~8 funções de auth/settings geradas pelo `phx.gen.auth` (login, sessão, magic link, trocar email/senha) a rodar sob bypass — espalhando o bypass sem ganho real (essas tabelas não guardam dado clínico). A defesa em profundidade fica em `invitations` agora e em **todo dado clínico** (`patients`/`sessions`/`records`/`audio`) nas fatias 1+, onde toda query é tenant-scoped. `users`/`tenants` ficam sob **scope explícito + email único global**. Onde este spec abaixo diz "RLS em users/tenants", vale este adendo.
2. **`Repo.with_registration_bypass_multi/1`** foi adicionado além do `with_registration_bypass/1`: rodar um `Ecto.Multi` dentro de `with_registration_bypass(fn -> Repo.transaction(multi) end)` aninhava transações e quebrava o tratamento de constraint. O `_multi` injeta o `SET LOCAL` como passos do próprio Multi (com reset de bypass no fim), evitando o aninhamento.

**Nota de teste:** os testes que exercitam `transact_tenant`/`with_*_bypass` no corpo são marcados `async: false` — `transaction + SET LOCAL` tem race sob o Ecto Sandbox concorrente (artefato de teste; produção usa transação curta por request). Serialização documentada nos próprios arquivos.

### Follow-ups conhecidos (do code review final — não bloqueantes, sem impacto de segurança)

- **Double-accept de convite (race):** dois aceites simultâneos do mesmo token — o 2º falha no `unique_index(:users, email)` e retorna `{:error, changeset}` em vez de `{:error, :already_accepted}`. UX confusa, sem corrupção. Tratar quando houver remoção de membros (`SELECT FOR UPDATE` no lookup ou traduzir o erro do step `:user`).
- **Re-convite bloqueado:** `unique_index(:invitations, [tenant_id, email])` impede reconvidar um email já convidado mesmo após o membro sair. Avaliar índice parcial `WHERE accepted_at IS NULL` quando entrar gestão de membros.
- **Email de convite fora da transação:** `deliver_invitation_email/3` roda após o commit e ignora o retorno do `Mailer`. Se o SMTP falhar, a invitation fica criada sem aviso. Logar a falha de entrega / expor variante de retorno.

---

## 1. Contexto e objetivo

Os docs em `docs/` descrevem o produto PsiCare inteiro (8 features). Este spec cobre **apenas a Fatia 0 — a Fundação**, que é o esqueleto que todas as outras fatias dependem: autenticação, multi-tenancy com isolamento real de dados, papéis (admin/therapist) e onboarding (solo + clínica com convite de membros).

Sem isolamento por tenant funcionando, nenhuma fatia de negócio pode nascer com segurança — vazamento de dado clínico entre tenants é falha crítica. Por isso a fundação entrega não só auth, mas o **mecanismo de isolamento (scope + RLS) testado**.

### Decomposição do produto (contexto)

| Fatia | Conteúdo | Depende de |
|---|---|---|
| **0 — Fundação** *(este spec)* | auth + multi-tenancy (RLS) + roles + onboarding | nada |
| 1 — Pacientes + Linhas de Pensamento | CRUD pacientes (scoped) + frameworks + associação | Fundação |
| 2 — Sessões + Prontuário SOAP (IA) | CRUD sessões + Oban + Claude gera SOAP | Pacientes |
| 3 — Sugestão de Abordagens (IA) | análise de perfil → cards | Sessões + Frameworks |
| 4 — Áudio WhatsApp (IA) | upload S3 → Whisper → Claude sugere resposta | Pacientes |
| 5 — Dashboard | agregações | tudo acima |

Cada fatia seguinte terá seu próprio ciclo spec → plan → implementação.

### Estado no início da Fatia 0 (snapshot histórico)

> Isto descreve o ponto de partida de **quando este spec foi escrito**. A Fatia 0 já está implementada (ver **Adendo de implementação** no topo). As seções abaixo refletem o desenho original; onde divergem do que foi construído, o adendo prevalece.

Phoenix 1.8.7 scaffold limpo (`Ravanshenasi` / `RavanshenasiWeb`), TimescaleDB HA pg17 rodando via Docker Compose, Credo + Dialyxir configurados, `mix precommit` passando. **Zero migrations, zero auth, zero contexts de negócio.** Marco zero de implementação.

---

## 2. Decisões de arquitetura (aprovadas)

| # | Decisão | Escolha | Justificativa |
|---|---|---|---|
| D1 | Estrutura | Fatiar o produto; especificar a Fundação primeiro | Destrava todas as outras fatias |
| D2 | Multi-tenancy | `tenant_id` em toda tabela + **RLS no Postgres** | Defesa em profundidade pra dado clínico (recomendação dos docs) |
| D3 | Onboarding | Solo **+** clínica completo (convite de membros por email) | Cobre os dois planos do produto |
| D4 | Auth UX | Magic link **+** senha (padrão do `phx.gen.auth` 1.8) | Caminho nativo, menos atrito |
| D5 | Autorização | Admin **só gerencia** (membros/convites/plano), **não vê dado clínico**; cada profissional vê só os seus | Privacidade clínica forte |
| D6 | Isolamento técnico | Scope explícito no Ecto (muro principal) + RLS fail-closed (rede de segurança) com bypass cirúrgico | Sobrevive ao LiveView; testável; sem GUC vazando no pool |

### Sobreposição aos docs antigos (este spec vence)

Onde este spec diverge de `docs/ARCHITECTURE.md`, `docs/DATA_MODEL.md` e `docs/AI_DESIGN.md`, **este spec é a fonte de verdade** para a Fatia 0:

| Tema | Docs antigos | Este spec |
|---|---|---|
| Isolamento | "schema por tenant ou tenant_id (decidir)" | **`tenant_id` + RLS forçado**, nunca schema-per-tenant |
| Unicidade de email | "único por tenant" | **único global** (exigência do magic link) |
| Papéis | implícito em `users.role` | **role simples no `user`**, sem tabela `memberships` |

---

## 3. Modelo de dados

### Tabelas

**`tenants`**
| Coluna | Tipo | Notas |
|---|---|---|
| `id` | uuid (binary_id) | PK |
| `name` | string | nome da clínica ou do profissional solo |
| `plan` | enum (`solo`, `clinic`) | definido no registro |
| `inserted_at` / `updated_at` | timestamp | |

**`users`** (estende o que o `phx.gen.auth` gera)
| Coluna | Tipo | Notas |
|---|---|---|
| `id` | uuid | PK |
| `tenant_id` | uuid | FK → tenants, NOT NULL |
| `email` | citext | **único global** (ver D-email abaixo) |
| `hashed_password` | string | **nullable** (user só-magic-link) |
| `name` | string | |
| `role` | enum (`admin`, `therapist`) | |
| `confirmed_at` | utc_datetime | gerado pelo phx.gen.auth |
| `inserted_at` / `updated_at` | timestamp | |

**`users_tokens`** — gerado pelo `phx.gen.auth` (session, magic link, sudo, email-change). **Sem `tenant_id`** (referencia `user_id`); fica **fora do RLS-por-tenant** — protegida por token secreto/único + scope no app (ver §4).

**`invitations`**
| Coluna | Tipo | Notas |
|---|---|---|
| `id` | uuid | PK |
| `tenant_id` | uuid | FK → tenants, NOT NULL |
| `email` | citext | convidado |
| `role` | enum (`therapist`) | default therapist |
| `token` | binary | hash do token (o token cru vai no email) |
| `invited_by_user_id` | uuid | FK → users |
| `accepted_at` | utc_datetime | nullable |
| `expires_at` | utc_datetime | TTL do convite |
| `inserted_at` / `updated_at` | timestamp | |

Constraint: `unique(tenant_id, email)` — não convidar o mesmo email 2x no tenant.

### Decisões de modelagem

- **`email` único global** (não por tenant). Login magic-link-first precisa resolver um email para exatamente um user. Consequência: a mesma pessoa não pode ser solo **e** membro de clínica com o mesmo email no MVP. Os docs originais diziam "único por tenant", mas isso é incompatível com magic link — esta decisão sobrepõe os docs.
- **`role` direto no `user`** (sem tabela `memberships`), porque 1 user pertence a 1 tenant. Mais simples e suficiente. Migrar para `memberships` só se multi-tenant-membership virar requisito.
- **Solo:** o único user é `admin` do próprio tenant (gerencia plano) **e** atende — vê os próprios pacientes. A regra "vê só os seus" não conflita porque ele é o único profissional.
- **Clínica:** `admin` é gestor puro (não atende, não vê dado clínico dos therapists).
  - **Decisão consciente da Fatia 0 (restrição forte, risco conhecido):** o admin de clínica **não atende** nesta fatia — para atender, precisa de uma conta `therapist` separada (outro email). Sabemos que dono-que-também-atende é caso comum em clínica pequena e isso vai incomodar cedo; mantemos a restrição no MVP para reduzir complexidade (role único por user). **Reavaliar pós-MVP** — caminho provável é permitir um user com papel duplo ou um "modo atendimento" para o admin.

### Relacionamentos
```
Tenant 1──* User      (User.tenant_id, NOT NULL)
Tenant 1──* Invitation
User   1──* Invitation (invited_by_user_id)
```

### Extensões e índices

**Extensão (requisito de migration):** habilitar `citext` **antes** de criar `users` e `invitations`:
```elixir
execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"
```
> A migration de auth gerada pelo `phx.gen.auth` já inclui esse `CREATE EXTENSION citext`. Garantir que ela rode **antes** da migration de `invitations` (ordem de timestamp), já que `invitations.email` também é `citext`.

**Índices:**
| Tabela | Índice | Tipo |
|---|---|---|
| `users` | `email` | **unique** (global) |
| `users` | `tenant_id` | index (lookups por tenant) |
| `users_tokens` | gerados pelo `phx.gen.auth` (`context`/`token`, `user_id`) | — |
| `invitations` | `(tenant_id, email)` | **unique** |
| `invitations` | `token` | **unique** (hash do convite) |
| `invitations` | `tenant_id` | index (listagem do admin) |

---

## 4. Isolamento — duas camadas

### Camada 1 — Scope explícito (muro principal)

O `Scope` do Phoenix 1.8 (`Ravanshenasi.Accounts.Scope`) carrega `{user, tenant, role}`. Todo context recebe o scope e filtra explicitamente:
- `tenant_id` **sempre**;
- `user_id` do dono nos dados clínicos (fatias 1+).

É a defesa idiomática, testável e fácil de debugar.

```elixir
# Padrão em todos os contexts (exemplo da Fatia 1)
def list_patients(%Scope{} = scope) do
  Repo.transact_tenant(scope, fn ->
    Patient
    |> where(tenant_id: ^scope.tenant.id, user_id: ^scope.user.id)
    |> Repo.all()
  end)
end
```

### Camada 2 — RLS fail-closed (rede de segurança)

RLS **forçado** (`ENABLE` + `FORCE ROW LEVEL SECURITY`) nas tabelas abaixo. Como o conjunto de colunas difere, há três classes de policy — todas fail-closed, todas com o mesmo bypass:

| Classe | Tabelas | Coluna de match |
|---|---|---|
| **Tenant-scoped** | `users`, `invitations`, + todas as de negócio (Fatias 1+) | `tenant_id` |
| **Âncora** | `tenants` | `id` (é o próprio tenant) |
| **Fora do RLS-por-tenant** | `users_tokens` | — (sem `tenant_id`; protegida por token secreto + scope) |

**Policy tenant-scoped (fail-closed), `USING` + `WITH CHECK`:**
```sql
tenant_id = current_setting('app.current_tenant_id', true)::uuid
OR current_setting('app.auth_bypass', true) = 'on'
```
**Policy âncora (`tenants`)** — idêntica, trocando `tenant_id` por `id`.

- `current_setting(..., true)` usa `missing_ok = true`: sem GUC setado → `NULL` → comparação `false` → **0 linhas**. Fail-closed: query que esquece o contexto não vaza, retorna vazio.
- `WITH CHECK` é obrigatório: sob `FORCE RLS`, sem `WITH CHECK` os `INSERT`/`UPDATE` são bloqueados. A mesma cláusula serve pros dois.
### Contrato do `Repo.transact_tenant/2`

Mecanismo central do isolamento. **Contrato obrigatório:**

- **Toda** query tenant-scoped (leitura ou escrita de dado já vinculado a um tenant) **deve** rodar dentro de `Repo.transact_tenant(scope, fn -> … end)`. Fora dele, o RLS é fail-closed: **leitura** retorna 0 linhas; **escrita** é bloqueada pelo `WITH CHECK` (falha, não grava).
- A função **sempre** abre transação, faz `SET LOCAL app.current_tenant_id = scope.tenant.id`, executa a função e fecha a transação. `SET LOCAL` morre no fim da transação → **nada vaza no connection pool**, mesmo com LiveView (processo de vida longa).
- **Só aceita `%Scope{}` com tenant válido.** Recebe `%Scope{tenant: %Tenant{id: id}}`; com scope inválido/sem tenant, **levanta** (não silencia, não roda sem GUC). Isso impede uso acidental fora de um contexto autenticado.
- É o **único** caminho que seta `app.current_tenant_id`.

**Valor de retorno — devolve o resultado CRU de `fun.()`, não o `{:ok, _}` de `Repo.transaction/1`.** Internamente usa transação, mas desembrulha:
- Leitura → o valor direto (`list_patients` devolve a lista, não `{:ok, list}`).
- Função de contexto que faz um write → o `{:ok, struct}` / `{:error, changeset}` que **ela mesma** produziu flui cru (um `insert` que falha não gravou nada; não precisa de rollback).
- Falha de banco dentro da transação (ex.: `Repo.insert!`, violação de constraint) **propaga como exceção** e a transação reverte.
- Para abortar atomicamente **múltiplas** escritas dependentes, encapsule em `Ecto.Multi` dentro da `fun` (o `{:ok, _}` / `{:error, step, reason, _}` da Multi flui como valor cru). **Não** use `Repo.rollback/1` aqui — ele forçaria o `{:error, reason}` do `Repo.transaction/1` e o wrapper o trata levantando, mascarando o motivo.

```elixir
# assinatura pretendida — resultado cru, sem embrulho {:ok, _}
@spec transact_tenant(Scope.t(), (-> result)) :: result when result: term()
# transact_tenant(%Scope{tenant: nil}, _fun) -> raises ArgumentError

def transact_tenant(%Scope{tenant: %{id: id}}, fun) when is_function(fun, 0) do
  {:ok, result} =
    transaction(fn ->
      query!("SELECT set_config('app.current_tenant_id', $1, true)", [id])
      fun.()
    end)

  result
end
```
> O `with_auth_bypass/1` e o `with_registration_bypass/1` seguem a **mesma convenção de retorno cru** (setam `app.auth_bypass` em vez do tenant).

### Bypass cirúrgico (pré-tenant) — dois helpers nomeados

Alguns caminhos acontecem **antes de existir tenant no contexto** e precisam furar o RLS. Para manter auditabilidade, há **dois helpers com nomes distintos por intenção** — ambos fazem internamente `SET LOCAL app.auth_bypass = 'on'` (é o **mesmo GUC**; a separação é semântica no código Elixir, não privilégio diferente no banco):

**`Repo.with_auth_bypass/1` — só leitura pré-tenant (exatamente 3 lookups):**
1. login por email (resolve o user → depois o tenant);
2. resolução de token de sessão;
3. lookup da invitation por token (no aceite).

**`Repo.with_registration_bypass/1` — escrita pré-tenant (criação + selo do aceite):**
- `INSERT` de `tenant` + `user` no registro solo/clínica;
- no aceite de convite, **na mesma transação**: `INSERT` de `user` **e** `UPDATE` de `accepted_at` em `invitations` — ambos passam pela cláusula de bypass (`USING`/`WITH CHECK`).

- Tudo é **fail-closed por padrão**; cada bypass é decisão consciente e restrita, **auditável por `grep with_auth_bypass` / `grep with_registration_bypass`** — sem um guarda-chuva único pra "tudo".
- **Não** é fail-open global (rejeitada a policy `GUC IS NULL OR ...`, que abriria as tabelas sempre que faltasse GUC).

### Helpers de migration

Um helper reutilizável cria a policy (o argumento `column` cobre a classe âncora, que usa `id`):
```elixir
# em priv/repo/migrations — função compartilhada
def enable_tenant_rls(table, column \\ "tenant_id") do
  predicate = """
  #{column} = current_setting('app.current_tenant_id', true)::uuid
  OR current_setting('app.auth_bypass', true) = 'on'
  """

  execute("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY")
  execute("ALTER TABLE #{table} FORCE ROW LEVEL SECURITY")
  execute("""
  CREATE POLICY tenant_isolation ON #{table}
  USING (#{predicate})
  WITH CHECK (#{predicate})
  """)
end

# uso:
# enable_tenant_rls("users")
# enable_tenant_rls("invitations")
# enable_tenant_rls("tenants", "id")
```
> Nota de implementação: `FORCE ROW LEVEL SECURITY` garante que o RLS valha até para o owner da tabela. O usuário/role de conexão da app **não** pode ter `BYPASSRLS`. Validar no plano que a role do `DATABASE_URL` é uma role comum.

---

## 5. Fluxos

### 5.1 Registro solo
1. Form: nome do profissional, email, senha (opcional), nome do consultório.
2. Cria `tenant(plan: solo, name: <consultório>)` + `user(role: admin, tenant_id)`.
3. Envia magic link de confirmação (Swoosh).
4. Sessão iniciada. O solo-admin gerencia **e** atende.

### 5.2 Registro de clínica
1. Form: nome da clínica, nome do admin, email, senha.
2. Cria `tenant(plan: clinic)` + `user(role: admin)`.
3. Magic link de confirmação → sessão. Admin é gestor puro.

### 5.3 Convite de membro (só admin de clínica)
1. Admin preenche email + role (`therapist`).
2. Cria `invitation` com token (hash salvo, token cru no link) + `expires_at`.
3. Email com link de aceite.
4. Convidado abre o link → `with_auth_bypass` resolve a invitation pelo token → form (nome, senha opcional) → `with_registration_bypass` cria `user(tenant_id, role)` e marca `accepted_at` → sessão.

### 5.4 Login
- Magic link **ou** email + senha.
- Sudo mode (phx.gen.auth) exigido pra ações sensíveis: trocar email/senha, gerenciar plano, gerenciar membros.

---

## 6. Autorização

`Scope` carrega `{user, tenant, role}` e expõe `Scope.admin?/1` e `Scope.therapist?/1`. Um `on_mount`/plug exige role nas rotas de gestão.

| Ação | Quem pode |
|---|---|
| Convidar/remover membro, listar membros | `admin` (clínica) |
| Mudar plano do tenant | `admin` |
| Ver/editar **dado clínico** (pacientes, sessões, prontuários, áudios — fatias 1+) | **somente o dono** (`user_id`). **Sem bypass por role.** |

A regra D5 (privacidade-first) significa: **não existe** caminho em que `admin` veja dado clínico de outro user. O scope dos dados clínicos filtra por `user_id` sempre; o RLS por `tenant_id` é a rede de segurança entre tenants.

---

## 7. Erros e edge cases

| Situação | Comportamento |
|---|---|
| Email já em uso (unique global) | Erro claro no registro e no aceite de convite |
| Convite expirado / já aceito / token inválido | Mensagem dedicada, sem criar user |
| Aceitar convite logado em outra conta | Bloqueia com aviso (exige logout) |
| Query de dado de negócio fora de `transact_tenant` | **Leitura:** 0 linhas (fail-closed). **Escrita:** bloqueada pelo `WITH CHECK` (falha, não grava). Nunca vaza nem grava silenciosamente |
| User só-magic-link tenta logar por senha | Orienta a usar o link ou definir senha |
| Role da conexão tem BYPASSRLS / é superuser | **Teste afirma que não** (ver §8/§11); senão RLS é silenciosamente inútil |

---

## 8. Estratégia de testes

- **Teste-âncora de isolamento** *(justifica a fundação inteira)*: cria 2 tenants; garante que (a) o scope no Ecto nunca cruza e (b) com `app.current_tenant_id` do tenant A setado, uma query direta na tabela retorna **0 linhas** de dado do tenant B.
- **Teste do bypass**: `with_auth_bypass` acha user por email cross-tenant (login funciona); fora dele, a mesma query é fail-closed.
- **Autorização**: admin barrado em dado clínico; therapist barrado em rotas de gestão.
- **Fluxos**: registro solo, registro clínica, convite → aceite, login magic link + senha. Estende os testes que o `phx.gen.auth` já gera.
- **Role DB sem privilégio**: teste que afirma que a role de conexão da app **não é superuser e não tem `BYPASSRLS`** — senão todo o RLS é silenciosamente inútil. Checagem: `SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user` deve retornar `false, false`.
- **Sandbox + RLS**: validar no plano que o `Ecto.Adapters.SQL.Sandbox` convive com `SET LOCAL` (transações aninhadas/savepoints). Possível ponto de atrito; documentar a abordagem (ex.: setar o GUC dentro do sandbox por teste).

---

## 9. Componentes / estrutura de arquivos

```
lib/ravanshenasi/
  accounts.ex                 # context: registro solo/clínica, convites, membros, scope
  accounts/
    scope.ex                  # Scope: {user, tenant, role} + admin?/1, therapist?/1
    user.ex                   # +tenant_id, +role, +name
    user_token.ex             # (gerado)
    user_notifier.ex          # (gerado) + email de convite
    tenant.ex
    invitation.ex
  repo.ex                     # +transact_tenant/2, +with_auth_bypass/1, +with_registration_bypass/1
lib/ravanshenasi_web/
  user_auth.ex                # plug + on_mount, estendido com tenant no Scope
  live/
    user_*                    # login, registro, settings (gerados/estendidos)
    org/                      # registro de clínica, gestão de membros, convites
priv/repo/migrations/
  *_create_tenants.exs
  *_create_users_auth_tables.exs   # gerado pelo phx.gen.auth, + tenant_id/role/name
  *_create_invitations.exs
  *_enable_tenant_rls.exs          # ENABLE/FORCE RLS: users, invitations (tenant_id) + tenants (id); users_tokens fica fora
```

---

## 10. Fora de escopo (fatias futuras)

- CRUD de pacientes, sessões, prontuários, áudios, frameworks (Fatias 1+).
- Billing/cobrança real (só o campo `plan` existe).
- Mesma pessoa em múltiplos tenants com o mesmo email (exigiria modelo `memberships`).
- Admin de clínica que também atende como therapist (role único no MVP).
- App mobile / API JSON (Fase 2 do produto).

---

## 11. Critério de pronto (Definition of Done da Fatia 0)

- [ ] Migrations criam `tenants`, `users` (+auth tables), `invitations`; RLS forçado em `tenants` (`id`), `users` e `invitations` (`tenant_id`); `users_tokens` fora do RLS-por-tenant.
- [ ] Registro solo e registro de clínica funcionam ponta a ponta (com confirmação por email).
- [ ] Admin de clínica convida therapist; convidado aceita e entra no tenant certo.
- [ ] **Onboarding atômico:** registro solo, registro de clínica e aceite de convite são transacionais — `tenant` + `user` (registro) e `user` + `accepted_at` (aceite) comitam juntos ou nada; nunca pela metade.
- [ ] Login por magic link **e** por senha funcionam; sudo mode protege ações sensíveis.
- [ ] **Teste-âncora de isolamento passa** (scope + RLS comprovadamente fail-closed).
- [ ] `Repo.transact_tenant/2` respeita o contrato: sempre transação + `SET LOCAL`, **retorna o resultado cru de `fun.()`** (não `{:ok, _}`), e **levanta** com `%Scope{}` sem tenant válido.
- [ ] `with_auth_bypass` cobre exatamente os 3 lookups de leitura pré-tenant; `with_registration_bypass` cobre exatamente as escritas de criação pré-tenant (`INSERT` de tenant/user no registro; `INSERT` de user **+ `UPDATE` de `accepted_at`** no aceite). Nada além disso.
- [ ] **Teste afirma que a role DB da app não é superuser nem tem `BYPASSRLS`.**
- [ ] `mix precommit` verde (compile, format, credo --strict, test).
