# Design da IA

## Modelo utilizado

**Anthropic Claude** (via API) para todas as tarefas de linguagem:
- Geração de prontuários
- Sugestão de abordagens terapêuticas
- Sugestão de resposta a áudios

**OpenAI Whisper** (via API) para transcrição de áudio.

---

## Princípios gerais dos prompts

1. **Contexto sempre presente**: todo prompt inclui o perfil do paciente e histórico relevante
2. **Linhas de pensamento injetadas**: as frameworks ativas do paciente são descritas no system prompt
3. **Tom clínico e ético**: a IA é instruída a manter linguagem profissional e não fazer diagnósticos definitivos
4. **Output estruturado**: sempre pedimos JSON ou formato fixo para facilitar o parsing e exibição

---

## Feature 4 — Geração de Prontuário

### Trigger
Disparado quando o profissional finaliza uma sessão.

### Prompt strategy

**System prompt:**
```
Você é um assistente clínico especializado em psicologia. 
Sua função é gerar prontuários clínicos estruturados no formato SOAP 
a partir das notas de sessão fornecidas pelo terapeuta.

Seja preciso, objetivo e use linguagem clínica apropriada.
Não faça diagnósticos definitivos — use linguagem de hipótese ("sugere", "indica", "observa-se").
Nunca invente informações que não estejam nas notas fornecidas.
```

**User prompt:**
```
Perfil do paciente:
- Nome: {patient.name}
- Idade: {patient.age}
- Queixa principal: {patient.chief_complaint}
- Histórico relevante: {patient.relevant_history}

Sessões anteriores (resumo das últimas 3):
{last_sessions_summary}

Notas da sessão de hoje ({session.date}):
{session.notes}

Gere o prontuário no formato SOAP:
- S (Subjetivo): o que o paciente relatou
- O (Objetivo): observações do terapeuta
- A (Avaliação): análise clínica da sessão
- P (Plano): próximos passos terapêuticos

Responda apenas com o prontuário, sem introdução ou conclusão adicional.
```

### Output esperado
Texto estruturado em seções S/O/A/P, salvo no campo `records.content`.

---

## Feature 5 — Sugestão de Abordagens Terapêuticas

### Trigger
Manual ("Analisar paciente") ou automático após geração de prontuário.

### Prompt strategy

**System prompt:**
```
Você é um supervisor clínico em psicologia com amplo conhecimento em 
múltiplas abordagens terapêuticas. Sua função é analisar o perfil de um 
paciente e sugerir vertentes de abordagem para o próximo atendimento.

Baseie suas sugestões exclusivamente nas abordagens terapêuticas listadas 
pelo terapeuta. Seja específico, clínico e justifique cada sugestão com 
base no perfil do paciente.
```

**User prompt:**
```
Abordagens terapêuticas que o terapeuta utiliza:
{frameworks_com_descricao}
-- Exemplo:
-- TCC: Terapia Cognitivo-Comportamental. Foca em identificar e modificar 
--      padrões de pensamento disfuncionais...
-- ACT: Princípios de aceitação, desfusão cognitiva...

Perfil do paciente:
- Nome: {patient.name} | Idade: {patient.age}
- Queixa principal: {patient.chief_complaint}
- Histórico: {patient.relevant_history}

Histórico de sessões e prontuários recentes:
{recent_records_summary}

Gere entre 2 e 4 sugestões de abordagem para o próximo atendimento.
Responda em JSON com o seguinte formato:

[
  {
    "framework": "nome da abordagem",
    "justification": "por que essa abordagem faz sentido para este paciente",
    "techniques": ["técnica 1", "técnica 2"],
    "watch_out": "pontos de atenção ou riscos"
  }
]
```

### Output esperado
Array JSON com 2–4 objetos. Parseado e exibido em cards na UI.

---

## Feature 6 — Processamento de Áudio do WhatsApp

### Etapa 1: Transcrição (Whisper)

```elixir
# Call to the OpenAI Whisper API
# Audio file sent as multipart/form-data
# Model: whisper-1
# Language: pt (Portuguese)
```

### Etapa 2: Sugestão de resposta (Claude)

**System prompt:**
```
Você é um assistente de comunicação para psicólogos.
Sua função é analisar a mensagem de um paciente (transcrita de áudio) 
e sugerir uma resposta empática e profissional que o terapeuta pode enviar.

A resposta deve:
- Ser escrita em primeira pessoa (como se fosse o terapeuta)
- Ser empática e acolhedora
- Não fazer promessas ou afirmações clínicas definitivas
- Ter tom conversacional (é uma mensagem de WhatsApp)
- Ter entre 3 e 6 linhas
```

**User prompt:**
```
Contexto do paciente:
- Nome: {patient.name}
- Queixa principal: {patient.chief_complaint}
- Última sessão: {last_session_summary}

Mensagem do paciente (transcrita do áudio):
"{transcription}"

Sugira uma resposta para o terapeuta enviar via WhatsApp.
Responda apenas com o texto da mensagem sugerida, sem introdução.
```

### Output esperado
Texto da resposta sugerida. Exibido em campo editável na UI para o profissional revisar e copiar.

---

## Considerações éticas e de segurança

- A IA **nunca** sugere diagnósticos definitivos — apenas levanta hipóteses
- Os prompts incluem instrução explícita para não inventar informações
- Todo output da IA é revisável e editável pelo profissional antes de qualquer uso
- Dados de pacientes nunca são enviados para a IA sem consentimento claro nos termos de uso do SaaS
- Logs de chamadas à API de IA devem ser armazenados com `tenant_id` para auditoria

---

## Gestão de erros da IA

| Situação | Comportamento |
|---|---|
| Timeout da API | Retry automático até 3x, depois marca como `error` |
| Resposta malformada (JSON inválido) | Retry com instrução reforçada no prompt |
| Erro de autenticação | Alerta ao admin do tenant |
| Áudio ilegível / ruído | Whisper retorna transcrição parcial; exibir aviso ao profissional |
