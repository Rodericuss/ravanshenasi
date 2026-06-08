# Ravanshenasi / PsiCare

> `Less paperwork. More presence.`

AI-assisted clinical practice software for psychologists and therapy clinics.

Ravanshenasi is the Phoenix/Elixir codebase behind **PsiCare**: a multi-tenant web app that helps therapists manage patients, register sessions, generate **SOAP** records, analyze cases through configured therapeutic frameworks, and turn patient WhatsApp audios into transcriptions plus suggested replies.

## Why this exists

Psychologists usually lose good clinical time to work that is important but repetitive:

- writing structured records after every session
- switching from freeform notes to SOAP
- deciding the next therapeutic angle from memory instead of structure
- replying carefully to patient audio messages late at night
- keeping clinic data isolated across teams

PsiCare removes that drag.

## Pains it kills

| Pain | What PsiCare does |
|---|---|
| "I still need to write the SOAP note." | Finalizing a session enqueues AI generation of a draft SOAP record. |
| "I know this patient is complex, but I want structured perspective." | The app generates approach suggestions based on the patient profile, recent history, and active frameworks. |
| "This WhatsApp audio needs a careful response, not a rushed one." | Upload the audio, transcribe it, and get a suggested reply in the desired tone. |
| "I run a clinic, but I cannot risk data leakage between professionals." | Tenant isolation is enforced in Postgres with RLS, and practitioner ownership is enforced in the app layer. |
| "My dashboard is scattered across memory, chats, and paper notes." | Pending reviews, recent sessions, recent audios, and active patients live in one place. |

## Core use cases

### 1. Solo therapist

- creates a solo workspace
- registers patients
- writes session notes
- finalizes a session and reviews the generated SOAP
- uploads a patient audio and edits the suggested reply

### 2. Clinic admin

- creates a clinic tenant
- invites therapists by email
- manages the shared framework catalog
- does **not** access clinical data from therapists

### 3. Therapist inside a clinic

- accepts an invitation
- sees only their own patients, sessions, records, analyses, and audios
- uses tenant frameworks plus personal frameworks

## Features

### 🧠 AI-assisted documentation

- session notes -> SOAP draft
- asynchronous generation with Oban
- retry flow when provider calls fail
- manual review/edit after generation

### 🧩 Therapeutic framework engine

- tenant-level default frameworks
- therapist-owned custom frameworks
- per-patient framework activation
- AI suggestions constrained by active frameworks

### 🎙️ WhatsApp audio workflow

- upload `.ogg`, `.mp3`, `.m4a`, `.wav`
- transcribe with OpenAI-compatible ASR
- generate reply in one of three tones:
  - empathetic
  - informative
  - encouraging
- save edited response and copy it back to WhatsApp

### 🏥 Multi-tenant clinic model

- solo or clinic tenant plans
- clinic admin invitation flow
- therapist membership acceptance flow
- clinical access rules based on role + tenant plan

### 🔐 Privacy by design

- PostgreSQL Row Level Security
- fail-closed tenant policies
- explicit scope propagation through contexts
- ownership filtering by `user_id` for clinical records
- audio binaries discarded after transcription

## Product flow

```text
Register clinic or solo workspace
        ↓
Create / invite user
        ↓
Create patient
        ↓
Attach therapeutic frameworks
        ↓
Write session notes
        ↓
Finalize session
        ↓
Oban job generates SOAP draft
        ↓
Review record / analyze patient / process WhatsApp audio
```

## The tiny meme section

```text
Therapist at 6:00 PM:
"I'll write the SOAP after dinner."

Therapist at 11:47 PM:
S:
O:
A:
P:

PsiCare:
"I already drafted it."
```

## What the app actually contains

### Main bounded areas

| Context | Responsibility |
|---|---|
| `Accounts` | auth, tenants, invitations, role logic, onboarding |
| `Patients` | patient CRUD and patient-framework links |
| `Frameworks` | tenant catalog + therapist-owned thinking frameworks |
| `Sessions` | therapy sessions and finalize flow |
| `Records` | SOAP records, review state, retry generation |
| `Analyses` | AI-generated therapeutic suggestions |
| `AudioMessages` | audio upload flow, transcription, suggested replies |
| `AI` | provider abstraction, fallback, prompt builders |

### Main UI surfaces

- landing page
- dashboard
- patient list / detail
- thinking frameworks
- session list / detail
- WhatsApp audio inbox per patient
- clinic registration / invitation acceptance / team management

## Technical decisions worth knowing

### 1. Phoenix LiveView over SPA + API-first frontend

Why:

- simpler real-time UX for long-running jobs
- less frontend state duplication
- PubSub-driven updates fit session/record/audio workflows well
- fewer moving parts for an internal-product style app

### 2. `tenant_id` + PostgreSQL RLS instead of schema-per-tenant

Why:

- simpler operational model
- strong isolation without multiplying schemas
- lets the app use a single code path and still enforce fail-closed access

Implementation details:

- clinical tables carry `tenant_id`
- RLS reads `app.current_tenant_id`
- bypass exists only for carefully scoped pre-tenant flows
- direct queries without tenant context return no rows

### 3. Scope + RLS, not RLS alone

RLS isolates tenants. It does **not** isolate two therapists inside the same clinic.

So the app also scopes clinical queries by:

- `tenant_id`
- `user_id`

That is the critical privacy model:

- database protects tenant boundaries
- app protects practitioner boundaries

### 4. Oban for async work

Used for:

- SOAP generation
- approach suggestion generation
- audio transcription + reply generation

Why:

- durable jobs
- retries
- restart safety
- clean separation between UI actions and slow AI calls

### 5. OpenAI-compatible provider abstraction

The AI layer is intentionally provider-agnostic.

Current behavior:

- chat generation uses ordered provider fallback
- transcription uses ordered provider fallback
- the app can target OpenAI or any compatible endpoint, including NVIDIA NIM-style deployments

Why:

- swap providers by config
- reduce lock-in
- keep tests deterministic with stubs

### 6. Optional password + magic-link-friendly auth

The auth model supports:

- standard password login
- email token flows
- invitation acceptance

This matches the clinic onboarding problem better than forcing a single auth path.

### 7. Localized UI

The app negotiates `en` / `pt` locale at the plug and LiveView mount layers.

## Security model

This project takes the data model seriously.

### Tenant isolation

- tenant context is applied with transaction-local Postgres settings
- RLS policies are **FORCE**d and fail closed
- bypass is explicit and narrow

### Clinical ownership

- therapists only see their own clinical records
- clinic admins manage team and configuration, but not therapist clinical data
- solo admins can access clinical data because they are the actual practitioner for that tenant

### File privacy

- uploaded audio is copied to temp storage only long enough for processing
- after transcription, the binary is removed best-effort
- the database persists text artifacts, not the audio file itself

## Architecture snapshot

```text
Phoenix LiveView
    ↓
Contexts (Accounts, Patients, Sessions, Records, Analyses, AudioMessages)
    ↓
Repo.transact_tenant(scope, fn -> ...)
    ↓
PostgreSQL + RLS

User actions that need AI
    ↓
Oban jobs
    ↓
AI facade
    ↓
OpenAI-compatible provider(s)
```

## Notable implementation choices

- `Req` is the HTTP client for provider calls
- `Bandit` is the web adapter
- `Swoosh` handles email delivery
- `Gettext` handles localization
- `PubSub` pushes job state changes back into LiveViews
- composite foreign keys reinforce tenant/user/patient consistency

## Development setup

### Requirements

- Elixir `~> 1.15`
- Erlang/OTP compatible with the project
- Docker
- a PostgreSQL-compatible database, typically via the included TimescaleDB HA pg17 container

### Start the database

```bash
docker compose up -d
```

### Install, migrate, and build assets

```bash
mix setup
```

### Start the app

```bash
mix phx.server
```

Then open [`http://localhost:4000`](http://localhost:4000).

## Demo flow

If you want a quick visual tour:

```bash
mix run priv/repo/demo_seed.exs
```

That script creates:

- a demo solo practitioner
- sample patients
- one finalized session with a completed SOAP record
- one audio message entry

It also prints a magic-link path for immediate login.

## Environment variables

### Required in production

```bash
DATABASE_URL=
SECRET_KEY_BASE=
PHX_HOST=
PHX_SERVER=true
```

### AI configuration

```bash
AI_ORDER=openai
OPENAI_BASE_URL=https://api.openai.com/v1
OPENAI_API_KEY=
OPENAI_MODEL=gpt-4o-mini

AI_TRANSCRIPTION_ORDER=openai
OPENAI_TRANSCRIBE_MODEL=whisper-1
```

### Optional compatible providers

```bash
AI_ORDER=nim,openai
NIM_BASE_URL=
NIM_API_KEY=
NIM_MODEL=

AI_TRANSCRIPTION_ORDER=nim,openai
NIM_ASR_BASE_URL=
NIM_ASR_MODEL=
```

## Tests and quality gates

The repository already has broad coverage across contexts, workers, auth flows, LiveViews, and isolation rules.

- `59` test modules currently live under `test/`
- several isolation-sensitive suites intentionally run with `async: false`
- Oban runs in manual test mode
- AI HTTP integrations are stubbed through deterministic tests

Run the full project gate with:

```bash
mix precommit
```

## Interesting routes

| Route | Purpose |
|---|---|
| `/` | marketing / product landing page |
| `/painel` | dashboard |
| `/pacientes` | patient workspace |
| `/linhas` | therapeutic frameworks |
| `/pacientes/:patient_id/sessoes` | session list |
| `/pacientes/:patient_id/audios` | audio processing workflow |
| `/equipe` | clinic team management |

## Current product boundaries

Deliberately out of scope right now:

- direct WhatsApp API integration
- scheduling/calendar
- billing
- native mobile app
- long-term binary audio storage

## In one sentence

PsiCare is a clinically aware, multi-tenant Phoenix app that turns the messy operational edges of therapy work into structured, private, AI-assisted workflows.
