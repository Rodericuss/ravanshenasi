# Fatia 5 — Dashboard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **WORKFLOW CONSTRAINT (deste projeto, não-negociável):** Trabalhar **direto na `main`**, **SEM branches**. **NÃO commitar** — o usuário faz os commits. Este plano **não tem passos de commit**: cada task termina com testes verdes e deixa a working tree pronta. NÃO rodar `git add`/`git commit`/`git push`. Flag de teste verboso no Elixir 1.19 deste repo é `--trace` (NÃO `-v`).

**Goal:** Uma home clínica em `/painel` que agrega o trabalho do profissional (prontuários pendentes de revisão, áudios recentes, sessões recentes, pacientes ativos), com login passando a levar o clínico pra lá.

**Architecture:** Fatia de leitura pura — sem tabela/migration/IA/Oban/real-time. Funções de agregação cross-paciente (escopadas por `tenant_id`+`user_id`, com `preload :patient`) nos contexts donos; uma `DashboardLive.Index`; e `signed_in_path` decidindo por `clinical_access?`.

**Tech Stack:** Elixir 1.19 / Phoenix 1.8.7 / LiveView 1.1 / Ecto.

**Invariante crítico:** `Repo.transact_tenant/2` reseta o GUC no sucesso — **não aninhar**. As funções de agregação abrem a própria transação; a `DashboardLive` as chama no mount sequencialmente (fora de transação) — sem aninhamento. O `preload :patient` roda DENTRO do `transact_tenant` (GUC setado), então a RLS permite ler o patient do mesmo tenant.

---

## File Structure

| Arquivo | Responsabilidade |
|---|---|
| `lib/ravanshenasi/records.ex` | **Modificar:** `list_pending_review/2` (preload `:patient`) + `count_pending_review/1`. |
| `lib/ravanshenasi/audio_messages.ex` | **Modificar:** `list_recent/2` (preload `:patient`). |
| `lib/ravanshenasi/sessions.ex` | **Modificar:** `list_recent/2` (preload `:patient`, `desc_nulls_last: date`). |
| `lib/ravanshenasi/patients.ex` | **Modificar:** `count_active/1` + `list_recent/2`. |
| `lib/ravanshenasi_web/user_auth.ex` | **Modificar:** `signed_in_path` (Conn + Socket) via helper `signed_in_path_for_scope/1`. |
| `lib/ravanshenasi_web/live/dashboard_live/index.ex` | **Criar:** mount agrega + render dos 4 cards. |
| `lib/ravanshenasi_web/router.ex` | **Modificar:** `live "/painel"` no `live_session :require_clinical`. |

**Ordem:** T1–T4 (queries nos contexts) → T5 (signed_in_path) → T6 (rota + LiveView). Cada task é TDD.

**Contexto dos contexts (já existem):** cada um tem `import Ecto.Query`, `alias Ravanshenasi.Accounts.Scope`, `alias Ravanshenasi.Repo`, o privado `scoped/2` (filtra `tenant_id`+`user_id`) e `defdelegate transact_tenant(scope, fun), to: Repo`. Os schemas `Record`/`AudioMessage`/`Session` têm `belongs_to :patient`; `Patient` tem `field :name` e `field :status` (`Ecto.Enum [:active, :inactive, :waitlist]`); `Record` tem `field :reviewed` e `field :generation_status` + `patient_id`/`session_id`.

---

## Task 1: `Records.list_pending_review/2` + `count_pending_review/1`

**Files:**
- Modify: `lib/ravanshenasi/records.ex`
- Test: `test/ravanshenasi/records_test.exs`

Prontuários do dono `done` e **não revisados**, cross-paciente, escopados, `:patient` preloadado.

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/records_test.exs` (o setup já provê `scope: s`, `patient`, `session`, `record` pending e o helper `insert_record/3`; aqui criamos os estados via os contexts):
```elixir
  test "pending_review: só done+não-revisado do dono, com :patient preloadado", %{scope: s} do
    {:ok, p} = Ravanshenasi.Patients.create_patient(s, %{name: "Carla"})
    {:ok, sess} = Ravanshenasi.Sessions.create_session(s, p, %{notes: "n"})
    {:ok, rec} = insert_record(s, sess, p)
    {:ok, _done} = Records.complete(s, rec, "S:..\nP:..", "stub:m")

    assert Records.count_pending_review(s) == 1
    assert [r] = Records.list_pending_review(s)
    assert r.id == rec.id
    assert r.patient.name == "Carla"

    # marcado como revisado → some
    {:ok, _} = Records.mark_reviewed(s, r)
    assert Records.count_pending_review(s) == 0
  end

  test "pending_review não vaza pra outro profissional do mesmo tenant" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Ravanshenasi.Patients.create_patient(a, %{name: "PA"})
    {:ok, sess} = Ravanshenasi.Sessions.create_session(a, pa, %{notes: "n"})
    {:ok, rec} = insert_record(a, sess, pa)
    {:ok, _} = Records.complete(a, rec, "c", "m")

    assert Records.count_pending_review(a) == 1
    assert Records.count_pending_review(b) == 0
    assert Records.list_pending_review(b) == []
  end
```
> O `records_test.exs` precisa importar os fixtures de clínica. No topo já há `import Ravanshenasi.AccountsFixtures` (usado por `user_scope_fixture`); `clinic_admin_scope_fixture`/`therapist_scope_fixture` vêm do mesmo módulo.

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/records_test.exs --trace`
Expected: FAIL — `function Ravanshenasi.Records.count_pending_review/1 is undefined`.

- [ ] **Step 3: Implementar**

Em `lib/ravanshenasi/records.ex`, acrescentar (junto das funções públicas):
```elixir
  @doc "Prontuários do dono prontos mas não revisados (done + reviewed=false), recentes primeiro. Cross-paciente, escopado, com :patient."
  def list_pending_review(%Scope{} = scope, limit \\ 5) do
    transact_tenant(scope, fn ->
      Record
      |> scoped(scope)
      |> where([r], r.generation_status == :done and r.reviewed == false)
      |> order_by([r], desc: r.inserted_at)
      |> limit(^limit)
      |> preload(:patient)
      |> Repo.all()
    end)
  end

  @doc "Quantos prontuários do dono estão done e não revisados."
  def count_pending_review(%Scope{} = scope) do
    transact_tenant(scope, fn ->
      Record
      |> scoped(scope)
      |> where([r], r.generation_status == :done and r.reviewed == false)
      |> Repo.aggregate(:count)
    end)
  end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/records_test.exs --trace`
Expected: PASS (incl. os testes antigos de records).

---

## Task 2: `AudioMessages.list_recent/2`

**Files:**
- Modify: `lib/ravanshenasi/audio_messages.ex`
- Test: `test/ravanshenasi/audio_messages_test.exs`

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/audio_messages_test.exs` (setup provê `scope: s`, `patient: p`; `attrs/0` já existe no arquivo):
```elixir
  test "list_recent traz os áudios do dono, recentes primeiro, com :patient", %{scope: s, patient: p} do
    {:ok, m1} = AudioMessages.create_audio_message(s, p, attrs())
    {:ok, m2} = AudioMessages.create_audio_message(s, p, attrs())

    recents = AudioMessages.list_recent(s)
    assert Enum.map(recents, & &1.id) == [m2.id, m1.id]
    assert hd(recents).patient.name == "Maria"
  end

  test "list_recent não vaza pra outro profissional" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})
    {:ok, _} = AudioMessages.create_audio_message(a, pa, %{audio_path: "/tmp/x.ogg", original_filename: "a.ogg", tone: :empathetic})

    assert length(AudioMessages.list_recent(a)) == 1
    assert AudioMessages.list_recent(b) == []
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/audio_messages_test.exs --trace`
Expected: FAIL — `function ...list_recent/1 is undefined`.

- [ ] **Step 3: Implementar**

Em `lib/ravanshenasi/audio_messages.ex`, acrescentar (junto das funções públicas; o módulo já tem `alias ...AudioMessage`):
```elixir
  @doc "Áudios do dono mais recentes (cross-paciente, escopado), com :patient preloadado."
  def list_recent(%Scope{} = scope, limit \\ 5) do
    transact_tenant(scope, fn ->
      AudioMessage
      |> scoped(scope)
      |> order_by([m], desc: m.inserted_at)
      |> limit(^limit)
      |> preload(:patient)
      |> Repo.all()
    end)
  end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/audio_messages_test.exs --trace`
Expected: PASS.

---

## Task 3: `Sessions.list_recent/2`

**Files:**
- Modify: `lib/ravanshenasi/sessions.ex`
- Test: `test/ravanshenasi/sessions_finalize_test.exs`

`desc_nulls_last: date` (rascunho sem data não fura a ordem) + desempate `desc: inserted_at`. Preload `:patient`.

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/sessions_finalize_test.exs` (setup provê `scope: s`; `Patients`/`Sessions` já aliased):
```elixir
  test "list_recent: ordena por date desc com nulls por último, com :patient", %{scope: s} do
    {:ok, p} = Patients.create_patient(s, %{name: "Lia"})
    {:ok, dated} = Sessions.create_session(s, p, %{notes: "n", date: ~U[2026-05-01 10:00:00Z]})
    {:ok, no_date} = Sessions.create_session(s, p, %{notes: "n"})

    recents = Sessions.list_recent(s)
    # a com data vem antes da sem data (nulls last)
    assert Enum.map(recents, & &1.id) == [dated.id, no_date.id]
    assert hd(recents).patient.name == "Lia"
  end

  test "list_recent não vaza pra outro profissional" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})
    {:ok, _} = Sessions.create_session(a, pa, %{notes: "n"})

    assert length(Sessions.list_recent(a)) == 1
    assert Sessions.list_recent(b) == []
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/sessions_finalize_test.exs --trace`
Expected: FAIL — `function Ravanshenasi.Sessions.list_recent/1 is undefined`.

- [ ] **Step 3: Implementar**

Em `lib/ravanshenasi/sessions.ex`, acrescentar (o módulo já tem `alias ...Session`, `scoped/2`, `transact_tenant`):
```elixir
  @doc "Sessões do dono mais recentes (cross-paciente, escopado), data desc (nulls por último), com :patient."
  def list_recent(%Scope{} = scope, limit \\ 5) do
    transact_tenant(scope, fn ->
      Session
      |> scoped(scope)
      |> order_by([s], desc_nulls_last: s.date, desc: s.inserted_at)
      |> limit(^limit)
      |> preload(:patient)
      |> Repo.all()
    end)
  end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/sessions_finalize_test.exs --trace`
Expected: PASS.

---

## Task 4: `Patients.count_active/1` + `list_recent/2`

**Files:**
- Modify: `lib/ravanshenasi/patients.ex`
- Test: `test/ravanshenasi/patients_test.exs`

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi/patients_test.exs` (já usa `import Ravanshenasi.AccountsFixtures` e `alias Ravanshenasi.Patients`; setup com `scope`):
```elixir
  test "count_active + list_recent: só ativos do dono, recentes primeiro" do
    s = user_scope_fixture()
    {:ok, _p1} = Patients.create_patient(s, %{name: "Ana"})
    {:ok, p2} = Patients.create_patient(s, %{name: "Bia"})
    {:ok, inativo} = Patients.create_patient(s, %{name: "Cida"})
    {:ok, _} = Patients.inactivate_patient(s, inativo)

    assert Patients.count_active(s) == 2
    recents = Patients.list_recent(s)
    assert hd(recents).id == p2.id
    refute Enum.any?(recents, &(&1.id == inativo.id))
  end

  test "count_active/list_recent não vazam pra outro profissional" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, _} = Patients.create_patient(a, %{name: "PA"})

    assert Patients.count_active(a) == 1
    assert Patients.count_active(b) == 0
    assert Patients.list_recent(b) == []
  end
```
> Se `patients_test.exs` não tiver `clinic_admin_scope_fixture`/`therapist_scope_fixture` no escopo, eles vêm do mesmo `Ravanshenasi.AccountsFixtures` já importado.

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi/patients_test.exs --trace`
Expected: FAIL — `function Ravanshenasi.Patients.count_active/1 is undefined`.

- [ ] **Step 3: Implementar**

Em `lib/ravanshenasi/patients.ex`, acrescentar (o módulo já tem `scoped/2`, `transact_tenant`, `alias ...Patient`):
```elixir
  @doc "Quantos pacientes ativos o dono tem."
  def count_active(%Scope{} = scope) do
    transact_tenant(scope, fn ->
      Patient |> scoped(scope) |> where([p], p.status == :active) |> Repo.aggregate(:count)
    end)
  end

  @doc "Pacientes ativos do dono, mais recentes primeiro (cross-paciente, escopado)."
  def list_recent(%Scope{} = scope, limit \\ 5) do
    transact_tenant(scope, fn ->
      Patient
      |> scoped(scope)
      |> where([p], p.status == :active)
      |> order_by([p], desc: p.inserted_at)
      |> limit(^limit)
      |> Repo.all()
    end)
  end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/ravanshenasi/patients_test.exs --trace`
Expected: PASS.

---

## Task 5: `signed_in_path` por `clinical_access?` (Conn + Socket)

**Files:**
- Modify: `lib/ravanshenasi_web/user_auth.ex`
- Modify: `test/ravanshenasi_web/user_auth_test.exs`
- Modify: `test/ravanshenasi_web/live/user_live/registration_test.exs`

Hoje `signed_in_path/1` só casa `%Plug.Conn{}`; chamadas `signed_in_path(socket)` (3 LiveViews de registro/convite) caem no fallback `~p"/"`. Extrai a helper por scope. **Único teste que muda de destino:** `registration_test.exs:20` (`/` → `/painel`, porque `user_fixture` é solo-admin clínico e `mount_current_scope` carrega tenant).

- [ ] **Step 1: Escrever o teste que falha**

Acrescentar a `test/ravanshenasi_web/user_auth_test.exs` (já tem `use RavanshenasiWeb.ConnCase`, `alias Ravanshenasi.Accounts`; e `import Ravanshenasi.AccountsFixtures` — confirme no topo, senão acrescente):
```elixir
  describe "signed_in_path/1" do
    test "manda profissional (clínico) pra /painel via Conn" do
      scope = user_scope_fixture()
      conn = %Plug.Conn{assigns: %{current_scope: scope}}
      assert RavanshenasiWeb.UserAuth.signed_in_path(conn) == ~p"/painel"
    end

    test "manda profissional (clínico) pra /painel via Socket" do
      scope = user_scope_fixture()
      socket = %Phoenix.LiveView.Socket{assigns: %{current_scope: scope, __changed__: %{}}}
      assert RavanshenasiWeb.UserAuth.signed_in_path(socket) == ~p"/painel"
    end

    test "manda admin de clínica pra /users/settings" do
      admin = clinic_admin_scope_fixture()
      conn = %Plug.Conn{assigns: %{current_scope: admin}}
      assert RavanshenasiWeb.UserAuth.signed_in_path(conn) == ~p"/users/settings"
    end

    test "sem usuário → /" do
      conn = %Plug.Conn{assigns: %{current_scope: Accounts.Scope.for_user(nil)}}
      assert RavanshenasiWeb.UserAuth.signed_in_path(conn) == ~p"/"
    end
  end
```
> `Accounts.Scope` é o módulo `Ravanshenasi.Accounts.Scope` (via o `alias Ravanshenasi.Accounts` já presente). Se o arquivo não tiver `import Ravanshenasi.AccountsFixtures`, acrescente no topo (ele já é usado nos demais testes do arquivo via `%{user: user}` — confirme).

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi_web/user_auth_test.exs --trace`
Expected: FAIL — o `signed_in_path(conn)` de um scope clínico devolve `~p"/users/settings"` (comportamento antigo), não `~p"/painel"`; e o caso Socket cai em `~p"/"`.

- [ ] **Step 3: Implementar**

Em `lib/ravanshenasi_web/user_auth.ex`, **substituir** as duas cláusulas atuais de `signed_in_path/1` (a `%Plug.Conn{...} -> ~p"/users/settings"` e a `signed_in_path(_) -> ~p"/"`) por:
```elixir
  @doc "Returns the path to redirect to after log in (works with a Conn or a LiveView Socket)."
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: scope}}), do: signed_in_path_for_scope(scope)

  def signed_in_path(%Phoenix.LiveView.Socket{assigns: %{current_scope: scope}}),
    do: signed_in_path_for_scope(scope)

  def signed_in_path(_), do: ~p"/"

  # Clinical practitioner → dashboard; clinic admin (non-clinical) → settings; otherwise root.
  # clinical_access?/1 has a catch-all returning false, so an incomplete scope never raises.
  defp signed_in_path_for_scope(%Scope{user: %Accounts.User{}} = scope) do
    if Scope.clinical_access?(scope), do: ~p"/painel", else: ~p"/users/settings"
  end

  defp signed_in_path_for_scope(_), do: ~p"/"
```

- [ ] **Step 4: Ajustar o teste de registro que mudou de destino**

Em `test/ravanshenasi_web/live/user_live/registration_test.exs`, no teste "redirects if already logged in", trocar o destino esperado:
```elixir
        |> follow_redirect(conn, ~p"/painel")
```
(era `~p"/"`. O `user_fixture()` é solo-admin clínico; já logado, ao acessar `/users/register` o `on_mount` redireciona via `signed_in_path(socket)` → `/painel`.)

- [ ] **Step 5: Rodar e ver passar**

Run: `mix test test/ravanshenasi_web/user_auth_test.exs test/ravanshenasi_web/live/user_live/registration_test.exs --trace`
Expected: PASS. Rodar também `mix test test/ravanshenasi_web/controllers/user_session_controller_test.exs --trace` pra confirmar que o login via controller (scope com user nil no create) continua em `~p"/"` — **não deve quebrar**.

---

## Task 6: Rota `/painel` + `DashboardLive.Index`

**Files:**
- Modify: `lib/ravanshenasi_web/router.ex`
- Create: `lib/ravanshenasi_web/live/dashboard_live/index.ex`
- Test: `test/ravanshenasi_web/live/dashboard_live_test.exs`

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ravanshenasi_web/live/dashboard_live_test.exs`:
```elixir
defmodule RavanshenasiWeb.DashboardLiveTest do
  use RavanshenasiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{AudioMessages, Patients, Records, Sessions}

  setup %{conn: conn} do
    scope = user_scope_fixture()
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  test "vazio: mostra empty states e contagens zero", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/painel")
    assert has_element?(lv, "#card-pending-review")
    assert has_element?(lv, "#card-active-patients")
    assert render(lv) =~ "0"
  end

  test "renderiza cards com dados do dono + links corretos", %{conn: conn, scope: s} do
    {:ok, p} = Patients.create_patient(s, %{name: "Marcos"})
    {:ok, sess} = Sessions.create_session(s, p, %{notes: "n", date: ~U[2026-05-01 10:00:00Z]})
    {:ok, %{record: rec}} = Sessions.finalize_session(s, sess)
    {:ok, _} = Records.complete(s, rec, "S:..\nP:..", "stub:m")
    {:ok, audio} = AudioMessages.create_audio_message(s, p, %{audio_path: "/tmp/x.ogg", original_filename: "msg.ogg", tone: :empathetic})

    {:ok, lv, _} = live(conn, ~p"/painel")

    # prontuário pendente: nome do paciente + link pra sessão
    assert has_element?(lv, "#pending-review-#{rec.id}", "Marcos")
    assert has_element?(lv, ~s{#pending-review-#{rec.id} a[href="/pacientes/#{p.id}/sessoes/#{sess.id}"]})

    # áudio recente: filename + link
    assert has_element?(lv, "#recent-audio-#{audio.id}", "msg.ogg")
    assert has_element?(lv, ~s{#recent-audio-#{audio.id} a[href="/pacientes/#{p.id}/audios"]})

    # sessão recente + paciente ativo
    assert has_element?(lv, ~s{#recent-session-#{sess.id} a[href="/pacientes/#{p.id}/sessoes/#{sess.id}"]})
    assert has_element?(lv, ~s{#active-patient-#{p.id} a[href="/pacientes/#{p.id}"]})
  end

  test "não vaza dados de outro profissional do mesmo tenant", %{conn: conn} do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "Paciente de A"})

    conn_b = log_in_user(conn, b.user)
    {:ok, lv, _} = live(conn_b, ~p"/painel")
    refute render(lv) =~ "Paciente de A"
    refute has_element?(lv, "#active-patient-#{pa.id}")
  end

  test "clinic admin é barrado pelo live_session :require_clinical", %{conn: conn} do
    admin = clinic_admin_scope_fixture()
    conn = log_in_user(conn, admin.user)
    assert {:error, {:redirect, _}} = live(conn, ~p"/painel")
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/ravanshenasi_web/live/dashboard_live_test.exs --trace`
Expected: FAIL — rota `/painel` não existe.

- [ ] **Step 3: Adicionar a rota**

Em `lib/ravanshenasi_web/router.ex`, **dentro do `live_session :require_clinical`** (o bloco de `/pacientes`), acrescentar como primeira rota:
```elixir
      live "/painel", DashboardLive.Index, :index
```

- [ ] **Step 4: Implementar a LiveView**

Criar `lib/ravanshenasi_web/live/dashboard_live/index.ex`:
```elixir
defmodule RavanshenasiWeb.DashboardLive.Index do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.{AudioMessages, Patients, Records, Sessions}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       pending_review: Records.list_pending_review(scope),
       pending_review_count: Records.count_pending_review(scope),
       recent_audios: AudioMessages.list_recent(scope),
       recent_sessions: Sessions.list_recent(scope),
       active_count: Patients.count_active(scope),
       recent_patients: Patients.list_recent(scope)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>{gettext("Dashboard")}</.header>

      <section id="card-pending-review">
        <h3>{gettext("Records pending review")} ({@pending_review_count})</h3>
        <p :if={@pending_review == []}>{gettext("No records pending review.")}</p>
        <ul>
          <li :for={r <- @pending_review} id={"pending-review-#{r.id}"}>
            <.link navigate={~p"/pacientes/#{r.patient_id}/sessoes/#{r.session_id}"}>
              {r.patient.name} — {Calendar.strftime(r.inserted_at, "%d/%m/%Y")}
            </.link>
          </li>
        </ul>
      </section>

      <section id="card-recent-audios">
        <h3>{gettext("Recent audios")}</h3>
        <p :if={@recent_audios == []}>{gettext("No recent audios.")}</p>
        <ul>
          <li :for={a <- @recent_audios} id={"recent-audio-#{a.id}"}>
            <.link navigate={~p"/pacientes/#{a.patient_id}/audios"}>
              {a.patient.name} — {a.original_filename} ({a.status})
            </.link>
          </li>
        </ul>
      </section>

      <section id="card-recent-sessions">
        <h3>{gettext("Recent sessions")}</h3>
        <p :if={@recent_sessions == []}>{gettext("No recent sessions.")}</p>
        <ul>
          <li :for={se <- @recent_sessions} id={"recent-session-#{se.id}"}>
            <.link navigate={~p"/pacientes/#{se.patient_id}/sessoes/#{se.id}"}>
              {se.patient.name} — {session_date(se.date)} ({se.status})
            </.link>
          </li>
        </ul>
      </section>

      <section id="card-active-patients">
        <h3>{gettext("Active patients")} ({@active_count})</h3>
        <p :if={@recent_patients == []}>{gettext("No active patients.")}</p>
        <ul>
          <li :for={p <- @recent_patients} id={"active-patient-#{p.id}"}>
            <.link navigate={~p"/pacientes/#{p.id}"}>{p.name} ({p.status})</.link>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  defp session_date(nil), do: "—"
  defp session_date(%DateTime{} = d), do: Calendar.strftime(d, "%d/%m/%Y")
end
```

- [ ] **Step 5: Rodar e ver passar**

Run: `mix test test/ravanshenasi_web/live/dashboard_live_test.exs --trace`
Expected: PASS (5 testes).

---

## Final: validação da fatia inteira

- [ ] **Step 1: Suite completa**

Run: `mix test`
Expected: TODOS verdes (os ~290 anteriores + os novos da Fatia 5). Zero falhas. Atenção especial: `registration_test.exs` (destino ajustado pra `/painel`) e `user_session_controller_test.exs` (login via controller continua em `/`).

- [ ] **Step 2: precommit (format + credo + test)**

Run: `mix precommit`
Expected: verde. (Não há hook de `mix format` automático pra Elixir — se o precommit reclamar de formatação, rode `mix format` e repita.)

- [ ] **Step 3: Deixar pro usuário commitar**

**NÃO commitar.** Reportar arquivos alterados, contagem de testes, e o ajuste no fluxo de login (clínico → `/painel`). Working tree pronta.

---

## Self-Review (plano vs spec)

**Spec coverage:**
- §3 widgets / funções de agregação: T1 (Records pending review + count), T2 (AudioMessages.list_recent), T3 (Sessions.list_recent desc_nulls_last), T4 (Patients count_active + list_recent). Todas com preload `:patient` onde a spec pede. ✅
- §4 DashboardLive: T6 — mount agrega, render 4 cards com contagem/lista/empty/IDs. ✅
- §5 signed_in_path: T5 — helper Conn+Socket, `clinical_access?`, ajuste do teste de registro. ✅
- §6 autorização: rota no `live_session :require_clinical` (T6 Step 3) + teste de gate (clinic admin → redirect). Isolamento entre profissionais em cada função (T1–T4) e na LiveView (T6). ✅
- §7 edge cases: empty states (T6 teste "vazio"), admin barrado, isolamento. ✅
- §8 testes: contexts (escopo/isolamento), LiveView (cards + **href** + empty + gate), signed_in_path (Conn/Socket/clínico/admin/nil). ✅
- §11 DoD: cada item mapeia a uma task. ✅

**Placeholder scan:** sem TBD/TODO; todo step de código tem o código; comandos com expected output.

**Type consistency:** `list_pending_review/2`+`count_pending_review/1`, `AudioMessages.list_recent/2`, `Sessions.list_recent/2`, `Patients.count_active/1`+`list_recent/2` — assinaturas idênticas entre tasks e LiveView (T6 mount). Assigns: `pending_review`/`pending_review_count`/`recent_audios`/`recent_sessions`/`active_count`/`recent_patients` consistentes entre mount e render. IDs estáveis: `#card-*`, `#pending-review-<id>`, `#recent-audio-<id>`, `#recent-session-<id>`, `#active-patient-<id>`. ✅

**Blast radius do signed_in_path (verificado no código):** o ÚNICO teste que muda de destino é `registration_test.exs:20` (`/` → `/painel`), porque `user_fixture` é solo-admin clínico e `mount_current_scope` carrega tenant. `user_auth_test.exs` "redirects to settings" monta `Scope.for_user(user)` sem tenant → clinical_access? false → `/users/settings` (não quebra). `user_session_controller_test.exs` login → `/` porque o `current_scope` no `create` tem user nil (não quebra). Não há testes nos fluxos org/registration nem org/accept_invitation.
