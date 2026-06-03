# PsiCare — Visão Geral do Produto

## O que é

PsiCare é um SaaS voltado para psicólogos e terapeutas que centraliza o gerenciamento de pacientes, geração de prontuários e assistência por IA — incluindo análise de perfil e suporte à comunicação via áudio do WhatsApp.

## Problema que resolve

Psicólogos gastam tempo considerável em tarefas administrativas e de registro que poderiam ser assistidas por IA:
- Escrever prontuários manualmente após cada sessão
- Decidir abordagens terapêuticas sem um suporte estruturado de análise
- Responder mensagens de áudio de pacientes no WhatsApp de forma cuidadosa e contextualizada

## Quem usa

- **Profissional solo**: um psicólogo com sua própria conta, gerenciando sua carteira de pacientes
- **Clínica**: múltiplos profissionais sob uma mesma organização, cada um com acesso isolado aos seus próprios pacientes

O modelo é **SaaS multi-tenant**: cada conta (profissional ou clínica) é um tenant isolado.

## Proposta de valor central

> "Você cuida do paciente. A IA cuida do registro, da análise e da comunicação."

## Fluxo macro do sistema

```
Cadastro do paciente
       ↓
Registro de sessões (notas por sessão)
       ↓
Geração de prontuário do dia (IA)
       ↓
Sugestão de abordagens terapêuticas (IA, baseada no perfil)
       ↓
Análise de áudio do WhatsApp + sugestão de resposta (IA)
```

## Fora do escopo (por ora)

- App mobile (planejado para fase 2, usando o mesmo backend Phoenix)
- Integração direta com WhatsApp Business API (áudio é feito por upload manual)
- Agendamento de consultas
- Faturamento / gestão financeira
