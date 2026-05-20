<p align="center">
  <img src="https://img.shields.io/badge/Elixir-4B275F?style=for-the-badge&logo=elixir&logoColor=white" alt="Elixir"/>
  <img src="https://img.shields.io/badge/Phoenix-FD4F00?style=for-the-badge&logo=phoenixframework&logoColor=white" alt="Phoenix"/>
  <img src="https://img.shields.io/badge/LiveView-FD4F00?style=for-the-badge&logo=phoenixframework&logoColor=white" alt="LiveView"/>
  <img src="https://img.shields.io/badge/PostgreSQL-4169E1?style=for-the-badge&logo=postgresql&logoColor=white" alt="PostgreSQL"/>
  <img src="https://img.shields.io/badge/Node.js-339933?style=for-the-badge&logo=nodedotjs&logoColor=white" alt="Node.js"/>
  <img src="https://img.shields.io/badge/BEAM_VM-A90533?style=for-the-badge&logo=erlang&logoColor=white" alt="BEAM VM"/>
</p>

<h1 align="center">🧠 PsiCare — Ravanshenasi</h1>

<p align="center">
  <em>🩺 Você cuida do paciente. A IA cuida do registro, da análise e da comunicação.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-em%20desenvolvimento-yellow?style=flat-square" alt="Status"/>
  <img src="https://img.shields.io/badge/licença-privado-red?style=flat-square" alt="Licença"/>
  <img src="https://img.shields.io/badge/IA-Claude%20%2B%20Whisper-blueviolet?style=flat-square" alt="IA"/>
</p>

---

## 📋 Sobre o Projeto

**PsiCare** é um SaaS voltado para **psicólogos e terapeutas** que centraliza o gerenciamento de pacientes, geração de prontuários e assistência por IA — incluindo análise de perfil, sugestão de abordagens terapêuticas e suporte à comunicação via áudio do WhatsApp.

> 🎯 **Problema:** Psicólogos gastam tempo considerável em tarefas administrativas e de registro que poderiam ser assistidas por inteligência artificial.

---

## 🏗️ Stack Tecnológica

| Camada | Tecnologia | Justificativa |
|:---:|:---|:---|
| 💜 **Backend + Web** | Elixir + Phoenix + LiveView | Real-time sem JS complexo, concorrência nativa via BEAM VM |
| 🟢 **Assets & Tooling** | Node.js | Build de assets, dependências JS do LiveView |
| 🐘 **Banco de Dados** | PostgreSQL | Multi-tenant com RLS, robusto para dados clínicos |
| 🤖 **IA — Linguagem** | Anthropic Claude API | Prontuários, análise de perfil, sugestão de respostas |
| 🎙️ **IA — Áudio** | OpenAI Whisper API | Transcrição de áudio em português (pt-BR) |
| 🔐 **Autenticação** | phx.gen.auth | Solução nativa do ecossistema Phoenix |
| ☁️ **Storage** | S3 / Tigris | Upload e armazenamento de arquivos de áudio |
| ⚡ **Jobs Assíncronos** | Oban | Processamento em background (chamadas IA, transcrição) |

---

## ✨ Funcionalidades

| # | Feature | Descrição | IA |
|:---:|:---|:---|:---:|
| 1 | 🔑 **Autenticação & Multi-tenancy** | Login, registro, roles (`admin` / `therapist`), isolamento por tenant | — |
| 2 | 👤 **Cadastro de Pacientes** | Perfil completo, queixa principal, histórico, status, busca e filtros | — |
| 3 | 📝 **Registro de Sessões** | Notas por sessão, rascunho/finalização, vínculo com paciente | — |
| 4 | 📄 **Geração de Prontuário** | Prontuário SOAP gerado automaticamente ao finalizar sessão | 🤖 |
| 5 | 💡 **Sugestão de Abordagens** | Análise do perfil + sugestão de vertentes terapêuticas | 🤖 |
| 6 | 🎧 **Processamento de Áudio** | Upload de áudio WhatsApp → transcrição → sugestão de resposta | 🤖 |
| 7 | 🧩 **Linhas de Pensamento** | TCC, Psicanálise, Gestalt, ACT, DBT, Jung + customizáveis | — |
| 8 | 📊 **Dashboard** | Visão geral: sessões, prontuários pendentes, áudios recentes | — |

---

## 🔄 Fluxograma — Fluxo Principal do Sistema

```mermaid
flowchart TD
    A[🔑 Login / Registro] --> B[📊 Dashboard]
    B --> C[👤 Cadastro de Paciente]
    C --> D[📝 Nova Sessão]
    D --> E{✅ Finalizar Sessão?}
    E -- Não --> D
    E -- Sim --> F[🤖 IA: Gera Prontuário SOAP]
    F --> G[📄 Profissional Revisa Prontuário]
    G --> H{💡 Analisar Paciente?}
    H -- Sim --> I[🤖 IA: Sugere Abordagens Terapêuticas]
    I --> J[🃏 Exibe Cards de Sugestão]
    H -- Não --> B

    B --> K[🎧 Upload Áudio WhatsApp]
    K --> L[🎙️ Whisper: Transcrição]
    L --> M[🤖 Claude: Sugestão de Resposta]
    M --> N[✏️ Profissional Revisa e Copia]
    N --> B

    style A fill:#4B275F,color:#fff
    style F fill:#7C3AED,color:#fff
    style I fill:#7C3AED,color:#fff
    style L fill:#10B981,color:#fff
    style M fill:#7C3AED,color:#fff
```

---

## 🔄 Fluxo de Comunicação com IA

```mermaid
sequenceDiagram
    participant U as 👨‍⚕️ Profissional
    participant LV as ⚡ LiveView
    participant O as 📦 Oban (Job)
    participant AI as 🤖 Claude / Whisper
    participant DB as 🐘 PostgreSQL
    participant PS as 📡 PubSub

    U->>LV: Ação (finalizar sessão / upload áudio)
    LV->>O: Dispara job assíncrono
    LV-->>U: "Processando..." (indicador)
    O->>AI: Chamada à API (Claude / Whisper)
    AI-->>O: Resultado
    O->>DB: Salva resultado
    O->>PS: Notifica conclusão
    PS-->>LV: Atualiza UI em real-time
    LV-->>U: Resultado pronto ✅
```

---

## 🗄️ Modelo de Dados (Simplificado)

```mermaid
erDiagram
    TENANT ||--o{ USER : has
    TENANT ||--o{ THINKING_FRAMEWORK : has
    USER ||--o{ PATIENT : manages
    PATIENT ||--o{ SESSION : has
    PATIENT ||--o{ AUDIO_UPLOAD : has
    PATIENT }o--o{ THINKING_FRAMEWORK : uses
    SESSION ||--o| RECORD : generates
    AUDIO_UPLOAD ||--o| AUDIO_ANALYSIS : produces

    TENANT {
        uuid id PK
        string name
        enum plan "solo | clinic"
    }
    USER {
        uuid id PK
        string email
        string name
        enum role "admin | therapist"
    }
    PATIENT {
        uuid id PK
        string name
        date birth_date
        text chief_complaint
        enum status "active | inactive | waitlist"
    }
    SESSION {
        uuid id PK
        datetime date
        integer duration_minutes
        text notes
        enum status "draft | finalized"
    }
    RECORD {
        uuid id PK
        text content "Formato SOAP"
        boolean reviewed
        enum generation_status
    }
```

---

## 🚀 Como Rodar (em breve)

```bash
# 📦 Instalar dependências
mix deps.get
npm install --prefix assets

# 🐘 Configurar banco de dados
mix ecto.setup

# ⚡ Iniciar servidor
mix phx.server
```

> 🌐 Acesse [`localhost:4000`](http://localhost:4000) no navegador.

### 🔑 Variáveis de Ambiente

```env
ANTHROPIC_API_KEY=       # 🤖 Claude API
OPENAI_API_KEY=          # 🎙️ Whisper API
DATABASE_URL=            # 🐘 PostgreSQL
S3_BUCKET=               # ☁️ Storage
S3_ACCESS_KEY=           # ☁️ Storage
S3_SECRET_KEY=           # ☁️ Storage
SECRET_KEY_BASE=         # 🔐 Phoenix
```

---

## 👥 Multi-tenancy

| Modelo | Tipo | Descrição |
|:---:|:---|:---|
| 🏠 **Solo** | Profissional individual | Uma conta, um psicólogo, seus pacientes |
| 🏥 **Clínica** | Múltiplos profissionais | Organização com vários terapeutas, dados isolados por profissional |

> 🛡️ Isolamento via `tenant_id` em todas as tabelas + Row Level Security (RLS) no PostgreSQL.

---

## 🧠 Design Ético da IA

| Princípio | Implementação |
|:---|:---|
| 🚫 Sem diagnósticos definitivos | IA usa linguagem de hipótese ("sugere", "indica", "observa-se") |
| 📝 Revisão humana obrigatória | Todo output é editável pelo profissional antes do uso |
| 🔒 Privacidade de dados | Dados de pacientes nunca enviados sem consentimento nos termos de uso |
| 📋 Auditoria | Logs de chamadas à API armazenados com `tenant_id` |
| 🎯 Contexto fiel | IA nunca inventa informações — trabalha apenas com dados fornecidos |

---

## 📍 Roadmap

- [x] 📐 Definição de arquitetura e modelo de dados
- [x] 🤖 Design dos prompts de IA
- [ ] 🔑 Autenticação e multi-tenancy
- [ ] 👤 CRUD de pacientes
- [ ] 📝 Registro de sessões
- [ ] 📄 Geração de prontuários (IA)
- [ ] 💡 Sugestão de abordagens (IA)
- [ ] 🎧 Processamento de áudio (IA)
- [ ] 🧩 Configuração de linhas de pensamento
- [ ] 📊 Dashboard
- [ ] 📱 App mobile (Fase 2)

---

<p align="center">
  Feito com 💜 usando <strong>Elixir</strong>, <strong>Phoenix</strong> e <strong>BEAM VM</strong>
</p>
