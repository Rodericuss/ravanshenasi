# Fatia 5 — Dashboard

**Projeto:** Ravanshenasi (PsiCare) — SaaS de psicologia
**Data:** 2026-06-04
**Status:** Spec aprovado, pronto pra virar plano de implementação
**Depende de:** Fatias 0–4 (todas implementadas). Reusa Patients/Records/Sessions/AudioMessages.
**Stack:** Phoenix 1.8.7 + LiveView 1.1 + Ecto + TimescaleDB pg17

---

## 1. Contexto e objetivo

Última fatia do MVP (Feature 8 do `FEATURES.md`). Uma **home clínica** em `/painel` que dá ao profissional uma visão geral do seu trabalho, **agregando dados que já existem**. É uma fatia de **leitura/agregação pura**: sem tabelas novas, sem migration, sem IA, sem Oban, sem dado destrutivo. O que muda é uma `DashboardLive` e algumas funções de consulta cross-paciente (escopadas) nos contexts donos.

### API herdada (usar como está)
- `Ravanshenasi.Repo.transact_tenant/2`; `Scope` (`clinical_access?/1`).
- Contexts `Patients`, `Records`, `Sessions`, `AudioMessages` — cada um com seu `scoped/2` privado (`tenant_id`+`user_id`) e `defdelegate transact_tenant`.
- **Padrão de segurança (Fatias 1–4):** RLS isola por tenant; o scope isola entre profissionais. Toda query escopa por `tenant_id`+`user_id`. As funções deste dashboard são **cross-paciente** (sem filtro de `patient_id`), mas continuam escopadas por `user_id` — o profissional só vê o que é dele. **Nunca aninhar `transact_tenant`** (a `DashboardLive` chama cada função do context fora de transação, sequencialmente — sem aninhamento).

---

## 2. Decisões de arquitetura (aprovadas)

| # | Decisão | Escolha | Justificativa |
|---|---|---|---|
| F5-D1 | Rota | **`/painel` → `DashboardLive.Index`** no `live_session :require_clinical` | Dado clínico; admin de clínica não atende, não entra |
| F5-D2 | Login | **`signed_in_path`: clínico → `/painel`; admin → `/users/settings`** (por `clinical_access?`) | Hoje vai todo mundo pra settings (placeholder do gerador) |
| F5-D3 | Queries | **Funções de agregação nos contexts donos** (Patients/Records/Sessions/AudioMessages) | Cada context dono da sua tabela (padrão do projeto); sem god-context |
| F5-D4 | Real-time | **Sem PubSub** (snapshot no mount) | YAGNI; recarrega ao navegar de volta |
| F5-D5 | Persistência | **Nenhuma** (sem tabela/migration) | Só leitura agregada |

---

## 3. Widgets (4 cards)

Cada card: contagem (onde houver) + lista curta (top 5, escopada) + **empty state**.

| Card | Função(ões) no context dono | Critério / ordem | Exibe em cada item | Link |
|---|---|---|---|---|
| **Prontuários pendentes de revisão** | `Records.count_pending_review(scope)` + `Records.list_pending_review(scope, limit \\ 5)` | `generation_status == :done and reviewed == false`; `order_by [desc: inserted_at]` | `patient.name` + `inserted_at` | `~p"/pacientes/#{patient_id}/sessoes/#{session_id}"` |
| **Áudios recentes** | `AudioMessages.list_recent(scope, limit \\ 5)` | `order_by [desc: inserted_at]` | `patient.name` + `original_filename` + `status` | `~p"/pacientes/#{patient_id}/audios"` |
| **Sessões recentes** | `Sessions.list_recent(scope, limit \\ 5)` | rascunhos + finalizadas; `order_by [desc_nulls_last: date, desc: inserted_at]` | `patient.name` + `date` + `status` | `~p"/pacientes/#{patient_id}/sessoes/#{id}"` |
| **Pacientes ativos** | `Patients.count_active(scope)` + `Patients.list_recent(scope, limit \\ 5)` | `status == :active`; `order_by [desc: inserted_at]` | `name` + `status` | `~p"/pacientes/#{id}"` |

Notas:
- Todas as funções abrem o próprio `transact_tenant(scope, fn -> … end)` e usam o `scoped/2` do context (que já filtra `tenant_id`+`user_id`). São **cross-paciente** (não recebem `patient_id`).
- **Preload `:patient`** nas 3 funções cujos itens mostram o nome do paciente (`list_pending_review`, `AudioMessages.list_recent`, `Sessions.list_recent`) — via `preload: [:patient]` na query, dentro do `transact_tenant` (o patient é do mesmo tenant/dono, a FK composta garante; RLS permite ler). `Patients.list_recent` não precisa (é o próprio patient).
- **Ordenação de `Sessions.list_recent`:** `date` é **nullable** (rascunho pode não ter data). `desc` puro colocaria NULL antes no Postgres; usa-se **`desc_nulls_last: s.date`** + desempate `desc: s.inserted_at`, pra rascunhos sem data não aparecerem acima de sessões datadas.
- `count_*` retornam `integer` (via `Repo.aggregate(query, :count)`); `list_*` retornam `[struct]` (com `:patient` preloadado onde indicado).

---

## 4. `DashboardLive.Index`

- **Rota:** `live "/painel", DashboardLive.Index, :index` no `live_session :require_clinical`.
- **mount/3:** com o `scope = socket.assigns.current_scope`, agrega tudo (cada chamada abre sua transação, sequencial — sem aninhamento):
  ```
  assign(socket,
    pending_review: Records.list_pending_review(scope),
    pending_review_count: Records.count_pending_review(scope),
    recent_audios: AudioMessages.list_recent(scope),
    recent_sessions: Sessions.list_recent(scope),
    active_count: Patients.count_active(scope),
    recent_patients: Patients.list_recent(scope)
  )
  ```
- **render/1:** `<Layouts.app>` com 4 `<section>` (uma por card), cada uma com título, contagem (quando houver), lista (`:for`) com `<.link navigate={…}>` pro item, e empty state (`:if={@lista == []}`).
- IDs estáveis pros testes: `#card-pending-review`, `#card-recent-audios`, `#card-recent-sessions`, `#card-active-patients`, e por item `#pending-review-<record_id>`, `#recent-audio-<id>`, `#recent-session-<id>`, `#active-patient-<id>`.
- Sem `handle_event`/`handle_info` no MVP (snapshot estática; navegação via links).

---

## 5. `signed_in_path` (login)

`signed_in_path/1` é chamado tanto com `%Plug.Conn{}` (controller pós-login) **quanto com `%Phoenix.LiveView.Socket{}`** — hoje 3 LiveViews chamam `UserAuth.signed_in_path(socket)` (`registration_live.ex:56`, `org/registration_live.ex:53`, `org/accept_invitation_live.ex:44`), e isso cai no fallback atual `signed_in_path(_) → ~p"/"`. Pra a decisão valer nos dois casos, extraia uma helper privada por scope:

```elixir
def signed_in_path(%Plug.Conn{assigns: %{current_scope: scope}}), do: signed_in_path_for_scope(scope)
def signed_in_path(%Phoenix.LiveView.Socket{assigns: %{current_scope: scope}}), do: signed_in_path_for_scope(scope)
def signed_in_path(_), do: ~p"/"

defp signed_in_path_for_scope(%Scope{user: %Accounts.User{}} = scope) do
  if Scope.clinical_access?(scope), do: ~p"/painel", else: ~p"/users/settings"
end

defp signed_in_path_for_scope(_), do: ~p"/"
```

- **Fail-safe já garantido:** `Scope.clinical_access?/1` (`scope.ex:51-53`) tem catch-all `clinical_access?(_) → false` — um scope incompleto (ex.: `tenant: nil`) **não levanta**, cai no `false` → `/users/settings`. Sem loop de redirect. Scope sem `user` (não autenticado) cai na 2ª cláusula da helper → `~p"/"`.
- O `current_scope` no conn pós-login já vem com tenant (`fetch_current_scope_for_user` faz `Scope.for_user(user) |> with_tenant()`); no socket de registro o destino `/painel`/`/users/settings` é re-montado do zero pelo `on_mount` da rota destino (que recarrega o scope), então um scope ainda incompleto no momento da chamada não causa problema.
- **Mudança de comportamento (intencional):** os fluxos de registro/aceitar-convite que hoje redirecionam pra `~p"/"` passam a ir pra `/painel` (clínico) ou `/users/settings` (admin). O plano deve **ajustar os testes existentes** desses 3 LiveViews que assertam o redirect pra `"/"`.

---

## 6. Autorização

- `/painel` herda o gate do `live_session :require_clinical` (`on_mount :require_clinical_access`) — **admin de clínica é barrado no mount** (redirect).
- As funções de agregação não recebem struct do caller (só o `scope`), e escopam por `tenant_id`+`user_id` — não há como ver dado de outro profissional. RLS por tenant é a rede entre tenants.

---

## 7. Erros e edge cases

| Situação | Comportamento |
|---|---|
| Profissional sem nenhum dado | Cada card mostra seu **empty state** ("Nenhum prontuário pendente", "Nenhum áudio recente", etc.); contagens = 0 |
| Admin de clínica acessa `/painel` | Barrado no mount pelo `require_clinical_access` (redirect) |
| Dois profissionais do mesmo tenant | Cada um vê só os seus dados (queries escopadas por `user_id`); testado |
| Item linka pra recurso do dono | Os structs carregam `patient_id`/`session_id` próprios; os links levam às telas já existentes (que re-escopam) |

---

## 8. Estratégia de testes

`async: false` onde toca `transact_tenant`. Sem Oban/IA nesta fatia.

- **Contexts** (cross-paciente, escopo): `Records.list_pending_review`/`count_pending_review` só trazem `done`+não-revisados do dono; `AudioMessages.list_recent`/`Sessions.list_recent`/`Patients.list_recent`/`count_active` respeitam o limite e a ordem; **isolamento entre profissionais** do mesmo tenant (dados de A invisíveis pra B) em cada função.
- **`DashboardLive`**: renderiza os 4 cards com dados do dono (IDs estáveis) **e o texto útil** (nome do paciente, filename, status); não vaza item de outro therapist; empty states quando vazio. Acesso de **clinic admin → `{:error, {:redirect, _}}`** (gate da rota).
- **Links (regressão funcional):** o dashboard é basicamente navegação — os testes validam o **`href` gerado** dos itens principais, ex.: `has_element?(lv, ~s{#recent-audio-#{a.id} a[href="/pacientes/#{a.patient_id}/audios"]})` (idem prontuário → sessão, sessão recente, paciente ativo). Link errado aqui é regressão, não só cosmético.
- **`signed_in_path`**: para `%Plug.Conn{}` E para `%Phoenix.LiveView.Socket{}` — scope clínico → `~p"/painel"`; admin de clínica → `~p"/users/settings"`; sem usuário → `~p"/"`. O plano também atualiza os testes dos 3 LiveViews de registro/convite que esperavam redirect pra `"/"`.

---

## 9. Estrutura de arquivos

```
lib/ravanshenasi/patients.ex          # +count_active/1, +list_recent/2
lib/ravanshenasi/records.ex           # +count_pending_review/1, +list_pending_review/2
lib/ravanshenasi/sessions.ex          # +list_recent/2
lib/ravanshenasi/audio_messages.ex    # +list_recent/2
lib/ravanshenasi_web/live/dashboard_live/index.ex   # novo
lib/ravanshenasi_web/router.ex        # +live "/painel" no live_session :require_clinical
lib/ravanshenasi_web/user_auth.ex     # signed_in_path por clinical_access?
```

Sem migration, sem schema novo, sem worker, sem config nova.

---

## 10. Fora de escopo (fase 2)

- Próximas sessões do dia / agendamento (não há tabela de agendamento).
- Gráficos, métricas históricas, KPIs temporais.
- Real-time (PubSub) no dashboard.
- Dashboard de gestão pro admin de clínica (visão de equipe/faturamento).
- Paginação/filtros nos cards (top 5 basta no MVP).

---

## 11. Definition of Done

- [ ] `Records.list_pending_review/2` (preload `:patient`) + `count_pending_review/1` (done + não-revisado, escopado, cross-paciente).
- [ ] `AudioMessages.list_recent/2` (preload `:patient`), `Sessions.list_recent/2` (preload `:patient`, `order desc_nulls_last: date, desc: inserted_at`), `Patients.list_recent/2` + `Patients.count_active/1` — escopados, ordem/limit corretos.
- [ ] `DashboardLive.Index` em `/painel` (live_session `:require_clinical`): 4 cards com contagem/lista/empty state, **texto útil** (nome do paciente/filename/status) + IDs estáveis; **`href` dos links validado** nos testes.
- [ ] `signed_in_path_for_scope/1` (helper privada) cobrindo `%Plug.Conn{}` E `%Phoenix.LiveView.Socket{}`: clínico → `/painel`; admin → `/users/settings`; sem user → `/`. Testes dos 3 LiveViews de registro/convite ajustados.
- [ ] Autorização: clinic admin barrado no mount (testado via `live/2`); isolamento entre profissionais em cada função de agregação.
- [ ] `mix precommit` verde.
