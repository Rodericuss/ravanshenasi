# Features (backlog — Fatias 2–5)

> **Migrado para `docs/superpowers/specs/`:** Feature #1 (Autenticação e Multi-tenancy) → Fatia 0; Features #2 (Cadastro de Pacientes) e #7 (Configuração de Linhas de Pensamento) → Fatia 1. As seções abaixo são o backlog do que ainda **não** foi especificado. A numeração original é preservada para não quebrar referências.

## 3. Registro de Sessões

Cada sessão é vinculada a um paciente e tem sua própria descrição/notas.

**Campos por sessão:**
- Data e hora
- Duração (em minutos)
- Notas da sessão (texto livre — escrito pelo profissional)
- Status: rascunho / finalizada

**Comportamento:**
- Criar nova sessão a partir do perfil do paciente
- Editar notas enquanto status for rascunho
- Finalizar sessão (bloqueia edição, dispara geração de prontuário)

---

## 4. Geração de Prontuário (IA)

Ao finalizar uma sessão, a IA gera automaticamente um prontuário clínico estruturado.

**Input para a IA:**
- Perfil completo do paciente
- Notas da sessão atual
- Últimas N sessões anteriores (contexto)

**Output gerado:**
- Prontuário no formato SOAP (Subjetivo, Objetivo, Avaliação, Plano) ou equivalente clínico
- Salvo e vinculado à sessão
- O profissional pode revisar e editar antes de finalizar

**Comportamento:**
- Geração assíncrona (não bloqueia a UI)
- Indicador de status: gerando / pronto / erro
- Histórico de prontuários acessível pelo perfil do paciente

---

## 5. Sugestão de Abordagens Terapêuticas (IA)

A partir do perfil do paciente, a IA sugere diferentes vertentes de abordagem para o próximo atendimento.

**Trigger:**
- Acionado manualmente pelo profissional ("Analisar paciente") na página do paciente
- Ou automaticamente após geração do prontuário

**Input para a IA:**
- Perfil do paciente
- Histórico de sessões e prontuários
- Linhas de pensamento configuradas pelo profissional (ver Linhas de Pensamento — Fatia 1)

**Output:**
- 2 a 4 sugestões de abordagem, cada uma com:
  - Nome da abordagem / linha teórica
  - Justificativa baseada no perfil do paciente
  - Técnicas ou intervenções sugeridas
  - Possíveis pontos de atenção

**Comportamento:**
- Resultado exibido em cards na página do paciente
- Profissional pode salvar ou descartar sugestões
- Cada sugestão indica qual linha de pensamento foi usada

---

## 6. Processamento de Áudio do WhatsApp (IA)

O profissional recebe um áudio de um paciente via WhatsApp e faz upload no sistema.

**Fluxo:**
1. Profissional seleciona o paciente
2. Faz upload do arquivo de áudio (.ogg, .mp3, .m4a, .wav)
3. Sistema transcreve o áudio via Whisper
4. IA analisa a transcrição no contexto do perfil do paciente
5. IA gera uma sugestão de resposta em texto, como se fosse o profissional respondendo

**Input para a IA:**
- Transcrição do áudio
- Perfil do paciente
- Últimas sessões (contexto)
- Tom de resposta configurável (empático, informativo, encorajador, etc.)

**Output:**
- Transcrição exibida
- Sugestão de resposta em texto
- Profissional pode editar e copiar para enviar no WhatsApp

**Comportamento:**
- Upload aceita arquivos até 25MB
- Processamento assíncrono com indicador de progresso
- Histórico de áudios processados vinculado ao paciente

---

## 8. Dashboard

Visão geral rápida para o profissional:

- Próximas sessões do dia (quando houver agendamento, fase 2)
- Pacientes com sessões recentes
- Prontuários pendentes de revisão
- Áudios processados recentemente
