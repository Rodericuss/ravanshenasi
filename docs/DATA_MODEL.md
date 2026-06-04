# Modelo de Dados

## Entidades e Relacionamentos

```
Tenant
  └── has_many: Users
  └── has_many: ThinkingFrameworks (linhas de pensamento customizadas)

User (profissional)
  └── belongs_to: Tenant
  └── has_many: Patients

Patient
  └── belongs_to: User
  └── belongs_to: Tenant
  └── has_many: Sessions
  └── has_many: Records (via Sessions)
  └── has_many: AudioUploads
  └── many_to_many: ThinkingFrameworks

Session
  └── belongs_to: Patient
  └── has_one: Record

Record (prontuário)
  └── belongs_to: Session

AudioUpload
  └── belongs_to: Patient
  └── has_one: AudioAnalysis

ThinkingFramework
  └── belongs_to: Tenant (se customizada) | null (se pré-definida/global)
```

---

## Tabelas

### tenants
| Coluna | Tipo | Descrição |
|---|---|---|
| id | uuid | PK |
| name | string | Nome da clínica ou profissional |
| plan | enum | `solo`, `clinic` |
| inserted_at | timestamp | |

### users
| Coluna | Tipo | Descrição |
|---|---|---|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| email | string | Único por tenant |
| hashed_password | string | |
| name | string | |
| role | enum | `admin`, `therapist` |
| inserted_at | timestamp | |

### patients
| Coluna | Tipo | Descrição |
|---|---|---|
| id | uuid | PK |
| tenant_id | uuid | FK → tenants |
| user_id | uuid | FK → users (profissional responsável) |
| name | string | |
| birth_date | date | |
| phone | string | |
| email | string | |
| chief_complaint | text | Queixa principal |
| relevant_history | text | Histórico relevante |
| status | enum | `active`, `inactive`, `waitlist` |
| inserted_at | timestamp | |

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

### thinking_frameworks
| Coluna | Tipo | Descrição |
|---|---|---|
| id | uuid | PK |
| tenant_id | uuid | null = pré-definida/global |
| name | string | Ex: "TCC", "Psicanálise" |
| description | text | Princípios-guia (usado no prompt da IA) |
| is_predefined | boolean | true = vem do sistema |
| inserted_at | timestamp | |

### patient_frameworks (join table)
| Coluna | Tipo | Descrição |
|---|---|---|
| patient_id | uuid | FK → patients |
| thinking_framework_id | uuid | FK → thinking_frameworks |

---

## Índices importantes

```sql
-- Isolamento por tenant em todas as tabelas críticas
CREATE INDEX ON patients (tenant_id, user_id);
CREATE INDEX ON sessions (tenant_id, patient_id);
CREATE INDEX ON records (tenant_id, patient_id);
CREATE INDEX ON audio_uploads (tenant_id, patient_id);

-- Busca de pacientes
CREATE INDEX ON patients (tenant_id, status);
CREATE INDEX ON patients (tenant_id, name);
```

---

## Nota sobre Multi-tenancy

Todas as queries **devem** filtrar por `tenant_id` primeiro. No contexto do Ecto, isso será feito via um `Repo` wrapper ou um scope padrão que adiciona o filtro automaticamente, evitando vazamento de dados entre tenants.

```elixir
# Standard pattern in every context
def list_patients(%User{} = user) do
  Patient
  |> where(tenant_id: ^user.tenant_id, user_id: ^user.id)
  |> Repo.all()
end
```
