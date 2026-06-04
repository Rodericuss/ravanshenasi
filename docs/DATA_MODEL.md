# Modelo de Dados (backlog — Fatias 2–5)

> **Migrado para `docs/superpowers/specs/`:** `tenants`, `users`, `invitations` → Fatia 0; `patients`, `thinking_frameworks`, `patient_frameworks` → Fatia 1. As tabelas abaixo são o backlog ainda **não** especificado.

## Entidades restantes

```
Session
  └── belongs_to: Patient
  └── has_one: Record

Record (prontuário)
  └── belongs_to: Session

AudioUpload
  └── belongs_to: Patient
  └── has_one (campos): transcription + suggested_response
```

---

## Tabelas

### sessions
| Coluna | Tipo | Descrição |
|---|---|---|
| id | uuid | PK |
| patient_id | uuid | FK → patients |
| user_id | uuid | FK → users |
| tenant_id | uuid | FK → tenants |
| date | datetime | Data e hora da sessão |
| duration_minutes | integer | |
| notes | text | Notas escritas pelo profissional |
| status | enum | `draft`, `finalized` |
| inserted_at | timestamp | |

### records (prontuários)
| Coluna | Tipo | Descrição |
|---|---|---|
| id | uuid | PK |
| session_id | uuid | FK → sessions |
| patient_id | uuid | FK → patients |
| tenant_id | uuid | FK → tenants |
| content | text | Conteúdo gerado pela IA (formato SOAP) |
| reviewed | boolean | Se o profissional já revisou |
| generation_status | enum | `pending`, `generating`, `done`, `error` |
| inserted_at | timestamp | |

### audio_uploads
| Coluna | Tipo | Descrição |
|---|---|---|
| id | uuid | PK |
| patient_id | uuid | FK → patients |
| user_id | uuid | FK → users |
| tenant_id | uuid | FK → tenants |
| file_url | string | URL no S3 |
| file_name | string | |
| transcription | text | Resultado do Whisper |
| suggested_response | text | Sugestão de resposta da IA |
| processing_status | enum | `pending`, `transcribing`, `analyzing`, `done`, `error` |
| inserted_at | timestamp | |

---

## Nota sobre Multi-tenancy (padrão já implementado)

O padrão real, estabelecido na Fatia 0 e aplicado em todo dado clínico, é **RLS fail-closed por `tenant_id` + scope explícito** via `Repo.transact_tenant(scope, fn -> … end)` — não o `Repo`-wrapper antigo. Toda tabela clínica nova (`sessions`, `records`, `audio_uploads`) deve:

- ter `tenant_id` (+ `user_id` quando for dado do profissional) com FKs compostas tenant-aware;
- chamar `Ravanshenasi.RLS.enable_tenant_rls(tabela)` na migration;
- ser acessada exclusivamente dentro de `transact_tenant`.

Ver `docs/superpowers/specs/2026-06-03-fundacao-auth-multitenancy-design.md` e `docs/superpowers/specs/2026-06-03-fatia-1-pacientes-linhas-pensamento-design.md`.
