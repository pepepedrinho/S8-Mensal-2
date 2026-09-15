# Observabilidade — Triodelícia (Entrega Final)

Documentação objetiva da observabilidade implementada sobre a infraestrutura da primeira
entrega. Descreve as ferramentas, a coleta, as consultas, a fundamentação de **100% dos
painéis**, os testes e as limitações.

> **Segurança:** este repositório **não** contém credenciais, tokens, connection strings nem
> dados pessoais. Os logs foram desenhados para nunca registrar o conteúdo das tarefas, e a
> conexão com o banco não expõe a URI em mensagens de erro.

---

## 1. Ambiente e ferramentas

| Item | Valor |
|---|---|
| Provedor | Google Cloud |
| Aplicação | React (frontend) + Node.js/Express/Mongoose (backend) |
| Banco | Firestore Enterprise com compatibilidade MongoDB |
| Frontend (2 pontos) | `triodelicia-frontend-sae1` (southamerica-east1) e `triodelicia-frontend-saw1` (southamerica-west1) — Cloud Run |
| Backend | `triodelicia-backend` (southamerica-east1) — Cloud Run, ingress `internal-and-cloud-load-balancing` |
| Entrada / proxy reverso | Global External HTTPS Application Load Balancer (`/` → frontend, `/api/*` → backend) |
| Domínio / DNS | `triodelicia.duckdns.org` (DuckDNS) → IP global do LB, HTTPS com certificado gerenciado |
| **Observabilidade** | **Cloud Logging + Cloud Monitoring (nativos)** |
| Coleta de logs | `stdout` do Cloud Run → Cloud Logging (automático, sem agente) |
| Métricas | 6 métricas baseadas em logs + métricas nativas de Cloud Run + uptime check |
| Visualização | 1 dashboard do Cloud Monitoring com 6 painéis |
| Acesso à observabilidade | IAM: `roles/monitoring.viewer` + `roles/logging.viewer` |

**Por que Cloud Logging + Monitoring nativos:** integram-se diretamente com Cloud Run e Load
Balancer, permitem Logs Explorer, métricas baseadas em logs, dashboards e uptime checks sem
adicionar mais infraestrutura (Grafana/Prometheus foram descartados por exigir serviço, IAM,
deploy e manutenção extras).

---

## 2. Instrumentação e coleta

O backend escreve **uma linha JSON por evento** em `stdout`. O Cloud Run coleta `stdout` e o
Cloud Logging coloca cada JSON em `jsonPayload`, tornando os campos pesquisáveis e utilizáveis
por métricas.

### Onde os registros são gerados
`backend/logger.js` (o logger) e `backend/index.js` (que o usa nas rotas). Três tipos de evento:

- `http_request` — uma linha por requisição concluída (middleware).
- `db_operation` — uma linha por operação de banco observada pelo backend.
- `todo_listed` / `todo_created` / `todo_completed` / `todo_deleted` — eventos de negócio.

### Campos do log estruturado

| Campo | Exemplo | Finalidade |
|---|---|---|
| `timestamp` | `2026-09-15T17:32:10.120Z` | Tempo UTC / recorte temporal |
| `service` | `backend` | Filtrar o componente |
| `environment` | `production` | Separar ambiente |
| `severity` | `INFO` / `WARNING` / `ERROR` | Classificação e filtro |
| `event` | `http_request` / `db_operation` / `todo_created` | Tipo de evento |
| `method` | `GET` / `POST` / `PATCH` / `DELETE` | Análise HTTP |
| `route` | `/api/todos` / `/api/todos/:id` | Agrupamento por rota (padronizada) |
| `status_code` | `200` / `500` | Erros e sucesso |
| `duration_ms` | `37` | Desempenho |
| `operation` | `find` / `save` / `update` / `delete` / `findById` | Operação de banco |
| `success` | `true` / `false` | Banco e eventos |
| `error_type` | `CastError` / `MongoError` | Diagnóstico |
| `logging.googleapis.com/trace` | `projects/.../traces/…` | Correlação com o request log do Cloud Run |

**Nunca registrado:** senha, token, credencial, connection string, JWT, cookie, **texto da
tarefa**, e-mail ou qualquer dado pessoal.

### Onde ficam armazenados / retenção / como consultar
- **Armazenamento:** Cloud Logging (bucket `_Default` do projeto).
- **Retenção:** padrão do bucket `_Default` = **30 dias** (ajustável no Log Storage).
- **Consulta:** Logs Explorer (Console) ou `gcloud logging read`.

### Exemplo de registro e sua relação com um painel

Registro `http_request` gerado por uma requisição concluída:

```json
{
  "timestamp": "2026-09-15T17:32:10.120Z",
  "service": "backend",
  "environment": "production",
  "severity": "INFO",
  "event": "http_request",
  "method": "GET",
  "route": "/api/todos",
  "status_code": 200,
  "duration_ms": 37,
  "message": "GET /api/todos -> 200"
}
```

Este registro alimenta o **Painel 2 (Desempenho)**: a métrica de distribuição
`triodelicia_request_latency_ms` extrai `jsonPayload.duration_ms` (com `EXTRACT`) e o painel
plota p50/p95/p99 por rota. O mesmo registro, quando `status_code >= 500`, também alimenta o
**Painel 3 (Erros)** via `triodelicia_error_count`.

---

## 3. Métricas baseadas em logs

Definições versionadas em `observability/metrics/`. Todas filtram
`resource.type="cloud_run_revision"` e `resource.labels.service_name="triodelicia-backend"`.

| Métrica | Tipo | Extrai / conta | Alimenta o painel |
|---|---|---|---|
| `triodelicia_request_count` | Contador | requisições HTTP (label `route`, `status_code`) | 3 (denominador), 6 |
| `triodelicia_error_count` | Contador | requisições com `status_code >= 500` | 3 (numerador) |
| `triodelicia_request_latency_ms` | Distribuição | `EXTRACT(jsonPayload.duration_ms)` | 2 |
| `triodelicia_db_operation_count` | Contador | eventos `db_operation` (labels `operation`, `success`) | 4 |
| `triodelicia_db_operation_latency_ms` | Distribuição | `duration_ms` das operações de banco | 4 |
| `triodelicia_usage_event_count` | Contador | eventos de negócio (label `event`) | 6 |

No Monitoring, cada métrica baseada em logs tem o tipo
`logging.googleapis.com/user/<nome_da_métrica>`.

> Métricas baseadas em logs **não** processam logs antigos (sem backfill) e levam alguns minutos
> para aparecer no Monitoring. O tráfego de teste é gerado **depois** de criá-las.

---

## 4. Fundamentação dos 6 painéis (100%)

Padrão: **Pergunta · Motivo · Origem · Consulta/cálculo · Recorte/fuso · Visualização ·
Interpretação · Critérios de atenção · Ação · Validação · Limitações.**

### Painel 1 — Disponibilidade
- **Pergunta:** a aplicação está acessível pelo domínio configurado?
- **Motivo:** disponibilidade externa é o requisito mais básico; prova o caminho internet → LB → serviço.
- **Origem:** uptime check HTTPS em `https://triodelicia.duckdns.org/api/todos`; métrica `monitoring.googleapis.com/uptime_check/check_passed` (recurso `uptime_url`).
- **Consulta/cálculo:** `ALIGN_FRACTION_TRUE` em janelas de 5 min → fração de verificações bem-sucedidas.
- **Recorte/fuso:** 1–6 h, alinhamento 300 s; painel em America/Sao_Paulo (UTC−3), logs em UTC.
- **Visualização:** linha da fração de sucesso (1 = 100% ok).
- **Interpretação:** 1,0 = saudável; quedas indicam indisponibilidade.
- **Critérios de atenção:** qualquer falha confirmada ou falhas consecutivas. *Critério de demonstração, não SLO comercial.*
- **Ação:** verificar LB, certificado, saúde dos Cloud Run e DNS.
- **Validação:** cenários A/B (site no ar → sucesso), horário anotado.
- **Limitações:** primeiros minutos podem ficar sem dados (propagação); mede o endpoint externo, não cada revisão interna.

### Painel 2 — Desempenho
- **Pergunta:** quais rotas demoram mais e em quais períodos?
- **Motivo:** detectar lentidão antes que vire erro/timeout.
- **Origem:** log `http_request` → `triodelicia_request_latency_ms` (`jsonPayload.duration_ms`, label `route`).
- **Consulta/cálculo:** percentis `ALIGN_PERCENTILE_50/95/99`, unidade **ms**, por rota.
- **Recorte/fuso:** 1–3 h, alinhamento 60 s, UTC−3.
- **Visualização:** série temporal p50/p95/p99 (percentis mostram a cauda que a média esconde).
- **Interpretação:** p95/p99 estável = saudável; subida sustentada = degradação.
- **Critérios de atenção:** p95/p99 acima do baseline observado no teste; sem baseline, aumento claro e sustentado. *Definir o período do baseline.*
- **Ação:** investigar a rota lenta (banco, cold start, payload).
- **Validação:** cenário B (volume forma série visível).
- **Limitações:** mede duração no backend, não o tempo de rede até o usuário.

### Painel 3 — Erros
- **Pergunta:** quais falhas ocorrem e qual a parcela das requisições?
- **Motivo:** número absoluto de erros engana sem o total; é preciso a **parcela**.
- **Origem:** `triodelicia_error_count` (numerador, 5xx) e `triodelicia_request_count` (denominador, todas).
- **Consulta/cálculo:** duas séries `ALIGN_RATE` (req/s). **Numerador = erros 5xx; denominador = total de requisições** no mesmo recorte; taxa = erros ÷ total.
- **Recorte/fuso:** 1–3 h, 60 s, UTC−3.
- **Visualização:** duas linhas (erros/s vs total/s) para leitura direta da proporção.
- **Interpretação:** erros ≈ 0 em fluxo nominal; qualquer 5xx sustentado é anomalia.
- **Critérios de atenção:** taxa de 5xx > 0 em fluxo nominal ou pico durante teste de falha. *Explicar o denominador.*
- **Ação:** abrir os logs `ERROR` correlacionados (rota, `error_type`).
- **Validação:** cenário C (ID inválido → 500 real → pico no painel).
- **Limitações:** observa 5xx do backend; erros apenas no cliente/rede não aparecem aqui.

### Painel 4 — Banco de dados
- **Pergunta:** as operações do backend com o banco funcionam e com qual duração?
- **Motivo:** o banco é dependência crítica do CRUD.
- **Origem:** log `db_operation` → `triodelicia_db_operation_count` (labels `operation`, `success`) e `triodelicia_db_operation_latency_ms`.
- **Consulta/cálculo:** contagem `ALIGN_RATE` agrupada por `success`/`operation`; latência em percentis (ms).
- **Recorte/fuso:** 1–3 h, 60 s, UTC−3.
- **Visualização:** barras empilhadas sucesso vs falha (+ latência).
- **Interpretação:** predomínio de `success=true` = saudável; surgimento de `false` = falha real.
- **Critérios de atenção:** falha > 0 ou aumento de `duration_ms` acima do baseline. *Separar falha real de ausência de dados.*
- **Ação:** investigar OIDC/Firestore, rede ou a operação específica.
- **Validação:** cenário A (operações ok) + C (`findById` falha e registra `success=false`).
- **Limitações:** enxerga a operação pela ótica do backend, não a telemetria interna do Firestore.

### Painel 5 — Redundância
- **Pergunta:** como os dois pontos de atendimento do frontend se comportam?
- **Motivo:** a arquitetura tem frontend em duas regiões; é preciso comprovar que ambos atendem.
- **Origem:** métrica **nativa** `run.googleapis.com/request_count` (recurso `cloud_run_revision`), agrupada por `service_name` — confirmada no projeto, não assumida.
- **Consulta/cálculo:** `ALIGN_RATE` + `REDUCE_SUM` por `service_name`.
- **Recorte/fuso:** 1–6 h, 60 s, UTC−3.
- **Visualização:** uma linha por frontend, comparando a distribuição.
- **Interpretação:** ambos com tráfego = redundância ativa; queda total de um = ponto fora.
- **Critérios de atenção:** queda de tráfego/health em um backend ou concentração anormal em um só ponto. *Usar apenas métricas realmente disponíveis.*
- **Ação:** verificar saúde do NEG/serviço da região afetada.
- **Validação:** cenário E (os dois serviços existem e recebem tráfego).
- **Limitações:** sem teste destrutivo de failover (derrubaria produção); a distribuição depende do roteamento do LB, administrado pelo Google — **limitação declarada**.

### Painel 6 — Uso da aplicação
- **Pergunta:** quais funcionalidades são usadas e como o volume varia?
- **Motivo:** entender o uso real e detectar sumiço inesperado de atividade.
- **Origem:** eventos `todo_listed/created/completed/deleted` → `triodelicia_usage_event_count` (label `event`), **sem** conteúdo da tarefa.
- **Consulta/cálculo:** `ALIGN_RATE` + `REDUCE_SUM` por `event`.
- **Recorte/fuso:** 1–6 h, 60 s, UTC−3.
- **Visualização:** barras empilhadas por tipo de evento.
- **Interpretação:** mix de eventos coerente com o uso; predominância de `todo_listed` é esperada.
- **Critérios de atenção:** mudança inesperada de volume, sobretudo ausência total de eventos em horário de teste. *Ausência de dados ≠ ausência de uso sem verificar a coleta.*
- **Ação:** confirmar se a coleta parou ou se o uso realmente caiu.
- **Validação:** cenário A (create/complete/delete/list em horário anotado).
- **Limitações:** conta eventos, não usuários únicos; não registra conteúdo (privacidade).

---

## 5. Interpretação de períodos sem dados

Ausência de pontos **não** significa "zero erros" ou "funcionamento normal": pode ser ausência
de coleta ou de tráfego. Antes de concluir, verifique se houve requisições no período (Painel 6 /
`triodelicia_request_count`) e se as métricas já haviam sido criadas quando o tráfego ocorreu
(sem backfill). Cada indicador observa apenas parte do sistema; o alcance está descrito na
fundamentação de cada painel.

---

## 6. Testes e evidências

Cenários executados (scripts no roteiro de comandos):

| Cenário | Ação | Evidência esperada |
|---|---|---|
| A — Uso normal | CRUD completo pelo domínio | Logs HTTP+DB+negócio; painéis 1,2,4,6 com dados |
| B — Volume | sequência de requisições | Séries visíveis em 2,3,6 |
| C — Falha controlada | ID inválido → 500 real | Log `ERROR` + pico nos painéis 3 e 4 |
| D — Recuperação | tráfego normal | Painéis voltam ao esperado |
| E — Redundância | comprovar 2 frontends + tráfego | Distribuição por `service_name` no painel 5 |

**Para cada print, registrar:** cenário, data e hora, período selecionado no painel, o que era
esperado, o que foi observado e a conclusão. Um mesmo cenário pode validar mais de um painel
(relação explicada). O funcionamento normal é restaurado após os testes.

> Modelo de legenda de evidência:
> `Cenário C — 2026-09-15 14:32 (UTC−3) — Painel 3, janela de 1h — esperado: pico de 5xx e queda de volume nominal — observado: 1 erro CastError às 14:32, taxa de 5xx sobe e retorna a zero — conclusão: painel reflete a falha controlada.`

---

## 7. Estrutura do diretório

```text
observability/
├── README.md              # este arquivo
├── metrics/               # 6 definições de métricas (YAML)
│   ├── request_count.yaml
│   ├── error_count.yaml
│   ├── request_latency.yaml
│   ├── db_count.yaml
│   ├── db_latency.yaml
│   └── usage_count.yaml
├── dashboard.json         # dashboard dos 6 painéis
├── alert_errors.json      # (opcional) alerta de 5xx
├── diagrama.mmd           # diagrama — fonte editável (Mermaid)
├── diagrama.drawio        # diagrama — fonte editável (draw.io)
└── diagrama.png           # diagrama — versão legível (exportada)
```

Os arquivos de roteiro pessoal (`COMANDOS_*.md`) e os `.env*` **não** ficam no repositório.
