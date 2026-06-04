# Fatia 1 — Pacientes + Linhas de Pensamento

**Projeto:** Ravanshenasi (PsiCare) — SaaS de psicologia
**Data:** 2026-06-03
**Status:** Spec aprovado, pronto pra virar plano de implementação
**Depende de:** Fatia 0 (Fundação — auth + multi-tenancy RLS). Ver `2026-06-03-fundacao-auth-multitenancy-design.md`.
**Stack:** Phoenix 1.8.7 + LiveView 1.1 + Ecto + TimescaleDB HA pg17

---

## 1. Contexto e objetivo

Segunda fatia do produto. Sobre a Fundação já entregue (auth, tenants, RLS, scope), esta fatia adiciona o **núcleo clínico**: cadastro e gestão de **pacientes** (scoped por profissional) e a configuração de **linhas de pensamento** (frameworks terapêuticos) que cada paciente pode ter associadas. Os frameworks são a base que a IA das Fatias 2–3 vai consumir (a `description` de cada linha entra no prompt).

É a **primeira fatia que cria dado clínico de verdade** — portanto a primeira a aplicar RLS por `tenant_id` em tabelas de negócio, seguindo o padrão consolidado na Fatia 0 (ver Adendo de implementação do spec da Fundação): RLS fail-closed + acesso exclusivamente via `Repo.transact_tenant/2`.

### API herdada da Fatia 0 (usar como está)
- `Ravanshenasi.Accounts.Scope` = `%Scope{user, tenant}` + `for_user/1`, `put_tenant/2`, `admin?/1`, `therapist?/1`.
- `Ravanshenasi.Repo.transact_tenant(scope, fn -> … end)` — retorna o resultado cru; levanta sem tenant.
- `Ravanshenasi.Repo.with_registration_bypass_multi/1` — roda um `Ecto.Multi` com `SET LOCAL` injetado como passos (sem aninhar transação).
- `Ravanshenasi.RLS.enable_tenant_rls(tabela)` — liga RLS fail-closed por `tenant_id`.
- Funções da Fatia 0 que esta fatia **estende**: `Accounts.register_solo/1`, `Accounts.register_clinic/1`.

---

## 2. Decisões de arquitetura (aprovadas)

| # | Decisão | Escolha | Justificativa |
|---|---|---|---|
| F1-D1 | Escopo da fatia | Pacientes **+** Linhas de Pensamento juntos | Paciente associa frameworks; deixa a base pronta pra IA |
| F1-D2 | Dono dos frameworks | `thinking_frameworks.user_id` **nullable**: `NULL` = catálogo do tenant; setado = próprio do profissional | Clínica define um padrão; profissional herda e estende |
| F1-D3 | Herança | **União simples** na listagem (`user_id IS NULL OR user_id = self`), sem override por nome | YAGNI; sem lógica de merge |
| F1-D4 | Seed das predefinidas | 7 linhas no **nível tenant** (`user_id NULL`), síncrono no `register_solo` e `register_clinic` via `with_registration_bypass_multi` | Uma vez por tenant; `accept_invitation` herda, não duplica |
| F1-D5 | Isolamento | RLS por `tenant_id` em `patients`, `thinking_frameworks`, `patient_frameworks` + scope explícito (`user_id` nos pacientes; `user_id IS NULL OR self` nos frameworks) | Padrão consolidado da Fatia 0 |
| F1-D6 | Exclusão de paciente | **Soft** via `status: :inactive`; sem hard delete na UI | Preserva histórico clínico das fatias futuras |
| F1-D7 | Associação paciente↔framework | Join `patient_frameworks`; **presença = ativa** | Simples; ativar = inserir, desativar = remover |

---

## 3. Modelo de dados

Todas as três tabelas: `:binary_id` PK, RLS por `tenant_id`, acessadas só via `transact_tenant`.

### `patients` (scope: `tenant_id` + `user_id` do dono)
| Coluna | Tipo | Notas |
|---|---|---|
| `id` | binary_id | PK |
| `tenant_id` | binary_id | FK → tenants, NOT NULL |
| `user_id` | binary_id | FK → users (profissional dono), NOT NULL |
| `name` | string | NOT NULL |
| `birth_date` | date | nullable |
| `phone` | string | nullable |
| `email` | string | nullable (não-único: paciente pode repetir/omitir) |
| `chief_complaint` | text | queixa principal |
| `relevant_history` | text | histórico relevante |
| `status` | enum (`active`, `inactive`, `waitlist`) | default `active` |
| `inserted_at`/`updated_at` | utc_datetime | |

Índices: `(tenant_id, user_id)`, `(tenant_id, user_id, status)`, e busca por nome `(tenant_id, user_id, name)`.

### `thinking_frameworks` (scope: `tenant_id` + `user_id IS NULL OR self`)
| Coluna | Tipo | Notas |
|---|---|---|
| `id` | binary_id | PK |
| `tenant_id` | binary_id | FK → tenants, NOT NULL |
| `user_id` | binary_id | FK → users, **NULLABLE** — `NULL` = catálogo do tenant; setado = próprio do profissional |
| `name` | string | NOT NULL |
| `description` | text | princípios-guia; injetado no prompt da IA (Fatia 3) |
| `is_predefined` | boolean | default `false`; `true` nas 7 semeadas |
| `inserted_at`/`updated_at` | utc_datetime | |

Índices: `(tenant_id, user_id)`; **unique `(tenant_id, user_id, name)` com `NULLS NOT DISTINCT`** (PG17) — impede nome duplicado tanto no catálogo do tenant quanto nos próprios de um profissional.

> **Nome igual entre catálogo e próprio é permitido** (`user_id` distinto: `NULL` vs `self`). Um profissional pode criar um "TCC" próprio mesmo havendo "TCC" no catálogo do tenant — coerente com a união simples (F1-D3): `list_frameworks` mostra **os dois**. Não há regra de changeset bloqueando isso (decisão consciente; reavaliar só se confundir o usuário na UI).

### `patient_frameworks` (join — scope: `tenant_id`)
| Coluna | Tipo | Notas |
|---|---|---|
| `id` | binary_id | PK |
| `tenant_id` | binary_id | FK → tenants, NOT NULL (pra RLS) |
| `patient_id` | binary_id | FK → patients, NOT NULL, `on_delete: :delete_all` |
| `thinking_framework_id` | binary_id | FK → thinking_frameworks, NOT NULL, `on_delete: :delete_all` |
| `inserted_at`/`updated_at` | utc_datetime | |

Unique: `(patient_id, thinking_framework_id)`. **Presença = ativa** (sem flag `active`).

### Integridade referencial tenant-aware

Para dado clínico, o banco — não só o RLS em runtime — deve garantir que registros relacionados são do **mesmo tenant**. Usar FKs **compostas** com `tenant_id`:

- **Pré-requisito** (unique indexes nas tabelas-alvo, pra permitir FK composta): `users (tenant_id, id)`, `patients (tenant_id, id)`, `thinking_frameworks (tenant_id, id)`. O índice em `users` é aditivo sobre a Fatia 0.
- `patients.user_id` → FK composta `(tenant_id, user_id)` → `users (tenant_id, id)`. O dono é sempre do mesmo tenant.
- `thinking_frameworks.user_id` → FK composta `(tenant_id, user_id)` → `users (tenant_id, id)`. Como `user_id` é nullable, a FK só é checada quando setado (MATCH SIMPLE) — catálogo (`user_id NULL`) passa livre.
- `patient_frameworks.patient_id` → FK composta `(tenant_id, patient_id)` → `patients (tenant_id, id)`.
- `patient_frameworks.thinking_framework_id` → FK composta `(tenant_id, thinking_framework_id)` → `thinking_frameworks (tenant_id, id)`.

Em Ecto: `references(:users, with: [tenant_id: :tenant_id], …)` no campo composto, com os unique indexes criados antes. Resultado: é **impossível no nível do banco** associar paciente e framework de tenants diferentes, ou dar um paciente a um dono de outro tenant.

---

## 4. Contexts (API)

Duas responsabilidades → dois contexts. Tudo recebe `%Scope{}` e roda em `transact_tenant`.

### `Ravanshenasi.Patients`
```
list_patients(scope, opts \\ [])      # opts: :status (filtro), :q (busca nome ilike)
get_patient(scope, id)                # nil se não for do scope
get_patient!(scope, id)
create_patient(scope, attrs)
update_patient(scope, patient, attrs)
change_patient(patient, attrs \\ %{})
inactivate_patient(scope, patient)    # status -> :inactive (soft "excluir")

list_patient_frameworks(scope, patient)        # frameworks ativos do paciente
activate_framework(scope, patient, framework)  # insere na join (valida visibilidade)
deactivate_framework(scope, patient, framework)# remove da join
```
`create_patient`/`update_patient` setam `user_id = scope.user.id` e `tenant_id = scope.tenant.id` no servidor (nunca do form).

### `Ravanshenasi.Frameworks`
```
list_frameworks(scope)                 # tenant_id AND (user_id IS NULL OR user_id = self)
get_framework!(scope, id)
create_tenant_framework(scope, attrs)  # user_id = NULL (catálogo); exige admin
create_own_framework(scope, attrs)     # user_id = scope.user.id
update_framework(scope, framework, attrs)   # authz conforme dono (ver §6)
delete_framework(scope, framework)     # cascade remove associações
default_frameworks()                   # os 7 (name + description) em código
seed_defaults_steps(multi, tenant_id)  # passos de Multi pro seed (nível tenant)
```

> Duas funções de criação (`tenant_framework` vs `own_framework`) deixam a autorização explícita no nome, em vez de uma flag ambígua.

---

## 5. Seed das linhas predefinidas

`Frameworks.default_frameworks/0` devolve os 7 (TCC, Psicanálise, Psicologia Analítica/Jung, Gestalt-terapia, ACT, DBT, Humanista/Centrada na Pessoa) com `description` de princípios-guia.

`Frameworks.seed_defaults_steps(multi, tenant_id)` adiciona ao `Ecto.Multi` um `Multi.insert_all(:frameworks, ThinkingFramework, rows)` com as 7 linhas: `tenant_id` setado, `user_id: nil`, `is_predefined: true` (e `inserted_at`/`updated_at` preenchidos, já que `insert_all` não passa por changeset).

**Integração (estende a Fatia 0):**
- `Accounts.register_solo/1` e `Accounts.register_clinic/1`: depois dos passos que criam `tenant` + `user`, encadeiam `Frameworks.seed_defaults_steps(multi, tenant.id)`. Tudo roda no mesmo `with_registration_bypass_multi`.
- `Accounts.accept_invitation/2`: **não muda** — o therapist herda o catálogo do tenant.
- **Migration de backfill:** para tenants já existentes sem catálogo, insere as 7 (`user_id: NULL`) por tenant. Idempotente (só insere onde não há frameworks `user_id IS NULL`).
  - **Atenção RLS:** quando o backfill roda, `thinking_frameworks` já tem RLS `FORCE` + `WITH CHECK`, então um `INSERT` sem GUC é **bloqueado**. A migration deve, dentro da sua transação, `execute "SET LOCAL app.auth_bypass = 'on'"` **antes** dos inserts (o `WITH CHECK` aceita pela cláusula de bypass). Sem isso o backfill falha. Alternativa equivalente: setar `app.current_tenant_id` por tenant no loop — mas o bypass é mais simples para uma operação administrativa única.

---

## 6. Autorização

**A autorização é imposta no _context_, não na UI** (a UI só reflete). Helper `Scope.clinical_access?/1` (extensão pequena e aditiva do `Scope` da Fatia 0) distingue quem **atende** de quem só gerencia:

```elixir
def clinical_access?(%Scope{user: %{role: :therapist}}), do: true
def clinical_access?(%Scope{user: %{role: :admin}, tenant: %{plan: :solo}}), do: true
def clinical_access?(_), do: false
```

Solo-admin atende (plan `:solo`); admin de clínica (plan `:clinic`) **não**. Todo CRUD de pacientes, frameworks próprios e associação **chama por esse guard primeiro** e retorna `{:error, :unauthorized}` quando falha — mesmo que a UI já esconda o caminho.

| Recurso | Regra no context |
|---|---|
| Pacientes (CRUD + associação) | `clinical_access?(scope)` **e** dono (`user_id = scope.user.id`). Admin de clínica → `{:error, :unauthorized}`. Sem acesso cross-user. |
| Catálogo do tenant (`thinking_frameworks` com `user_id NULL`) — criar/editar/deletar | `Scope.admin?(scope)` (inclui admin de clínica **e** solo-admin). Config terapêutica da casa, não dado clínico — não fere D5 da Fatia 0. |
| Frameworks próprios (`user_id = self`) — criar/editar/deletar | `clinical_access?(scope)`. Admin de clínica → `{:error, :unauthorized}` (não tem paciente pra associar). |
| Associar/desassociar framework a paciente | Dono do paciente (logo, `clinical_access?`), usando qualquer framework visível (catálogo do tenant + próprios). |

**UI por papel** (sem ambiguidade):
- **Admin de clínica:** vê **Linhas de Pensamento** (gerencia o catálogo do tenant), mas **não** vê **Pacientes** (não atende — veria lista vazia). Não cria frameworks próprios (não há paciente seu pra associar).
- **Therapist e solo-admin:** veem **ambos** — Pacientes e Linhas (catálogo herdado + próprios).

RLS por `tenant_id` é a rede de segurança entre tenants; o scope no Ecto é o muro principal entre users.

---

## 7. Erros e edge cases

| Situação | Comportamento |
|---|---|
| `get_patient`/`get_framework` de outro user/tenant | `nil` → 404 (fail-closed: scope + RLS) |
| Associar framework **não visível** (de outro user, ou inexistente) ao paciente | Validação rejeita → `{:error, :not_found}` (não insere join) |
| `name` vazio / `status` inválido | Changeset com erro exibido no form |
| Criar framework de catálogo sem ser admin | `{:error, :unauthorized}` |
| `delete_framework` do catálogo com pacientes (de vários therapists) associados | Join com `on_delete: :delete_all` remove as associações. É ação consciente do admin; a UI avisa "isto remove a linha de N pacientes". |
| Nome de framework duplicado (mesmo escopo) | Erro de unique constraint traduzido no changeset |
| "Excluir" paciente | Vira `:inactive` (soft); some das listas ativas, recuperável |

---

## 8. Estratégia de testes

Seguindo o padrão da Fatia 0. **Testes que exercitam `transact_tenant`/bypass no corpo usam `use Ravanshenasi.DataCase, async: false`.** Motivo (ver "Nota de teste" no Adendo de implementação do spec da Fatia 0): `transaction + SET LOCAL` tem uma race intermitente sob o Ecto Sandbox quando os testes rodam em paralelo (a transação-mãe longa do Sandbox aborta); é artefato de teste — em produção cada request usa transação curta isolada. Não reverter pra `async: true`.

- **Teste-âncora clínico** (`async: false`): paciente do user A é invisível pro user B do **mesmo tenant** (scope `user_id`) **e** pro tenant B (RLS `tenant_id`). Prova as duas camadas.
- **Seed**: `register_solo` → 7 frameworks tenant-level (`user_id NULL`); `register_clinic` → 7; `accept_invitation` → **0 novos** (herda); backfill insere onde falta. (`async: false`.)
- **Herança/listagem**: `list_frameworks` devolve catálogo do tenant + próprios do user; não devolve próprios de **outro** user do mesmo tenant.
- **Autorização (no context)**: therapist não cria/edita catálogo do tenant; **admin de clínica recebe `{:error, :unauthorized}` ao chamar `create_patient`/`create_own_framework`/associação** (não só some da UI); solo-admin e therapist conseguem; associação cross-user bloqueada.
- **Associação**: ativar/desativar (presença na join); deletar framework remove associações.
- **Busca/filtro**: `ilike` por nome, filtro por `status`.
- **LiveView** (`Phoenix.LiveViewTest`): index de pacientes (busca/filtro), show (associar/desassociar), form (new/edit), index de frameworks (catálogo + próprios + criar).

---

## 9. Componentes / estrutura de arquivos

```
lib/ravanshenasi/
  patients.ex
  patients/patient.ex
  patients/patient_framework.ex          # join schema
  frameworks.ex
  frameworks/thinking_framework.ex
  frameworks/defaults.ex                  # os 7 (dados em código)
lib/ravanshenasi_web/live/
  patient_live/index.ex                   # lista + busca + filtro status
  patient_live/show.ex                    # perfil + frameworks ativos + associação
  patient_live/form.ex                    # new/edit
  framework_live/index.ex                 # catálogo do tenant + próprios + criar/editar
priv/repo/migrations/
  *_add_tenant_id_unique_to_users.exs     # unique (tenant_id, id) p/ FK composta (aditivo sobre Fatia 0)
  *_create_patients.exs                   # + unique (tenant_id, id) + composite FK + enable_tenant_rls
  *_create_thinking_frameworks.exs        # + unique (tenant_id, id) + composite FK + enable_tenant_rls
  *_create_patient_frameworks.exs         # + composite FKs (tenant_id, patient_id)/(tenant_id, framework_id) + enable_tenant_rls
  *_seed_default_frameworks_backfill.exs  # tenants existentes; SET LOCAL app.auth_bypass='on'
# estende: lib/ravanshenasi/accounts.ex (register_solo, register_clinic),
#          lib/ravanshenasi/accounts/scope.ex (+clinical_access?/1), router.ex
```

---

## 10. Fora de escopo (fatias futuras)

- Sessões, prontuários SOAP, áudio, sugestões de IA, dashboard (Fatias 2–5).
- Override de framework por nome (decidido: união simples; reavaliar se incomodar).
- Hard delete de paciente / anonimização LGPD (tratar quando houver política de retenção).
- Admin de clínica que também atende (herdado da Fatia 0 como decisão pós-MVP).
- Re-seed/sincronização do catálogo quando as 7 predefinidas mudarem (são estáticas no MVP).

---

## 11. Docs legados absorvidos por esta fatia

Estratégia: **encolher por absorção**. Ao implementar esta fatia, remover dos docs antigos as seções agora cobertas, rumo a "só `specs/` + `plans/`":
- `docs/FEATURES.md`: remover **#2 Cadastro de Pacientes** e **#7 Configuração de Linhas de Pensamento** (cobertos aqui); e **#1** (coberto pela Fatia 0).
- `docs/DATA_MODEL.md`: remover **patients**, **thinking_frameworks**, **patient_frameworks** (e tenants/users/invitations, já cobertos pela Fatia 0).
- Quando um doc legado ficar vazio, deletá-lo. O que sobra (sessões, prontuário, áudio, dashboard, visão geral) permanece como backlog até as fatias 2–5.

---

## 12. Definition of Done

- [ ] Migrations criam `patients`, `thinking_frameworks`, `patient_frameworks`, todas com `enable_tenant_rls`.
- [ ] **Integridade tenant-aware:** unique `(tenant_id, id)` em users/patients/thinking_frameworks + FKs compostas — banco recusa cruzar tenants (dono ou associação).
- [ ] CRUD de pacientes scoped (busca por nome + filtro por status); "excluir" = soft (`:inactive`).
- [ ] Seed das 7 no nível tenant via `register_solo`/`register_clinic`; **backfill sob `app.auth_bypass`** para tenants existentes; `accept_invitation` herda sem duplicar.
- [ ] `list_frameworks` faz união simples (catálogo do tenant + próprios do user); herança comprovada por teste.
- [ ] Associação paciente↔framework (ativar/desativar); associação cross-user bloqueada.
- [ ] Autorização **imposta no context** (não só UI): `Scope.clinical_access?/1` (therapist ou solo-admin) — admin de clínica recebe `{:error, :unauthorized}` em CRUD de pacientes, frameworks próprios e associação. Catálogo do tenant só por `admin?`. Pacientes só pelo dono. Coberto por teste.
- [ ] **Teste-âncora clínico passa** (scope `user_id` + RLS `tenant_id` fail-closed).
- [ ] Docs legados encolhidos (seções absorvidas removidas de FEATURES/DATA_MODEL).
- [ ] `mix precommit` verde (compile, format, credo --strict, test).
