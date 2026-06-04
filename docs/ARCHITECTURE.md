# Arquitetura

## Stack

| Camada | Tecnologia | Justificativa |
|---|---|---|
| Backend + Web | **Phoenix + LiveView** | Real-time sem JS complexo, Elixir é ideal pra concorrência e futuro de APIs |
| Banco de dados | **PostgreSQL** | Multi-tenant com RLS ou schema por tenant, robusto para dados clínicos |
| IA | **Anthropic API (Claude)** | Análise de texto, sugestão de abordagens, geração de prontuários, resposta a áudios |
| Transcrição de áudio | **OpenAI Whisper (API)** | Melhor custo-benefício para transcrição de áudio em português |
| Autenticação | **phx.gen.auth** | Solução nativa do ecossistema Phoenix |
| Storage de arquivos | **S3 / Tigris** | Upload de arquivos de áudio |

## Multi-tenancy

Modelo adotado: **um schema PostgreSQL por tenant** (ou `tenant_id` em todas as tabelas — decidir no início).

- Opção A — `tenant_id` em cada tabela: mais simples de manter, suficiente para começar
- Opção B — schema por tenant: isolamento total, mais complexo para migrations

**Recomendação inicial**: `tenant_id` em todas as tabelas com Row Level Security (RLS) no Postgres. Migrar para schemas se a escala exigir.

## Estrutura do Projeto Phoenix

```
lib/
  psicare/
    accounts/         # Users, tenants, authentication
    patients/         # Patient registration and profiles
    sessions/         # Therapy sessions and notes
    records/          # Generated records
    ai/               # AI integration modules
      profile_analysis.ex
      session_record.ex
      audio_response.ex
    whatsapp/         # Audio upload and processing
  psicare_web/
    live/
      patients/
      sessions/
      records/
      settings/       # Thought-line configuration
```

## Comunicação com IA

Todas as chamadas à IA são **assíncronas** — disparadas via `Task.async` ou jobs em background (Oban), para não bloquear o processo LiveView.

Fluxo:
```
LiveView recebe ação do usuário
       ↓
Dispara job assíncrono (Oban)
       ↓
Job chama Anthropic API / Whisper
       ↓
Resultado salvo no banco
       ↓
LiveView atualizado via PubSub
```

## Fase 2 — App Mobile

O backend Phoenix já será construído expondo uma **API JSON (REST ou GraphQL)** para as rotas que o app mobile vai consumir. LiveView é usado apenas na web. O app (provavelmente React Native ou Flutter) consome o mesmo backend.

## Variáveis de ambiente necessárias

```
ANTHROPIC_API_KEY=
OPENAI_API_KEY=          # Para Whisper
DATABASE_URL=
S3_BUCKET=
S3_ACCESS_KEY=
S3_SECRET_KEY=
SECRET_KEY_BASE=
```
