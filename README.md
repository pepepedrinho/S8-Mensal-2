# Triodelicia — To-Do App na Google Cloud (Mensal 2)

> **Atividade acadêmica.** Este repositório é o resultado da atividade **"Mensal 2"** da disciplina de infraestrutura em nuvem (Uniamérica, professor Laércio), do grupo **Triodelicia**. O projeto **não tem fins comerciais**: o objetivo é demonstrar, na prática, conceitos de infraestrutura serverless, segurança em camadas, DNS, proxy reverso e redundância na Google Cloud Platform (GCP), a partir de uma aplicação de exemplo já pronta (fork adaptado de [`aula-uniamerica-infraestrutura-cloud`](https://github.com/LaercioMLB/aula-uniamerica-infraestrutura-cloud)).

---

## 1. Sobre a aplicação

Um To-Do List simples, usado como base para a atividade — o foco avaliado não é a aplicação em si, e sim a infraestrutura ao redor dela.

| Camada | Tecnologia | Responsabilidade |
|---|---|---|
| Frontend | React + Nginx | Interface web, consome a API do backend em `/api/*` |
| Backend | Node.js + Express + Mongoose | API REST das tarefas (CRUD) |
| Banco de dados | Firestore Enterprise (compatibilidade MongoDB) | Persistência dos dados |

```text
S8-Mensal-2/
├── frontend/            # React + Dockerfile (Nginx)
├── backend/             # Node/Express + Dockerfile
├── banco-de-dados/      # Mongo local (uso exclusivo em desenvolvimento — não vai para produção)
├── docker-compose.yaml  # Ambiente local
├── cloudbuild-frontend.yaml
└── cloudbuild-backend.yaml
```

---

## 2. Objetivo da atividade

Construir, sobre uma aplicação já existente, uma infraestrutura **serverless** na nuvem aplicando conceitos de segurança, controle de acesso, DNS, proxy reverso e redundância — garantindo que cada componente (frontend, backend, banco) tenha o nível adequado de exposição e proteção.

### Requisitos exigidos pelo enunciado

- **Frontend:** acessível pela internet, serverless, HTTPS, redundante (≥2 pontos de execução), com mecanismo de distribuição de acesso, e domínio/subdomínio próprio (acesso não pode ser feito pela URL crua do provedor).
- **Backend:** serverless, **não exposto diretamente à internet**, acessado via API por trás de um proxy reverso, com regras de acesso definidas.
- **Banco de dados:** serviço gerenciado/serverless, **sem acesso público**, acessível somente pelo backend.
- **Domínio, DNS e proxy reverso:** fluxo `Usuário → DNS → Proxy Reverso → Front-end` e `Front-end → DNS/API → Proxy Reverso → Back-end`, tudo documentado em diagrama.
- **Segurança:** para cada componente, indicar firewall/mecanismo de controle de acesso — quem acessa, quem não acessa, porta, protocolo e onde o acesso é bloqueado.
- **Entrega:** infraestrutura funcionando pelo domínio, diagrama da arquitetura e documentação curta explicando as decisões.

---

## 3. Arquitetura implementada

```text
                         INTERNET
                             |
                             | HTTPS :443
                             v
                  +-----------------------+
                  | Global External HTTPS |   <- proxy reverso + balanceamento
                  | Application LB        |
                  +-----------------------+
                      |               |
                / (padrão)         /api/*
                      |               |
           +----------+----------+    |
           |                     |    |
           v                     v    v
  frontend-sae1          frontend-saw1   backend (privado)
  southamerica-east1     southamerica-west1   southamerica-east1
  (Cloud Run)             (Cloud Run)          (Cloud Run, ingress
           |                     |              internal-and-cloud-
           +----------+----------+              load-balancing)
                      |                              |
                Frontend React                       v
                                           Firestore Enterprise
                                          (compatibilidade MongoDB)
                                            southamerica-east1

DNS: triodelicia.duckdns.org  ->  IP público global do Load Balancer
```

### Mapa requisito → implementação

| Requisito da atividade | Como foi implementado |
|---|---|
| Frontend serverless | Cloud Run |
| HTTPS | Certificado gerenciado pelo Google no Load Balancer |
| Domínio/subdomínio próprio | `triodelicia.duckdns.org` (DuckDNS) |
| Acesso não pode ser pela URL do provedor | Frontend com ingress público só através do LB; usuário nunca acessa `*.run.app` |
| Redundância do frontend (≥2 pontos) | Dois serviços Cloud Run em regiões diferentes (`southamerica-east1` e `southamerica-west1`), cada um com seu Serverless NEG |
| Mecanismo de distribuição | Global External Application Load Balancer, com *backend service* único agregando os dois NEGs do frontend |
| Backend serverless | Cloud Run |
| Backend não exposto diretamente à internet | `--ingress=internal-and-cloud-load-balancing` — só aceita tráfego vindo do próprio Load Balancer |
| Proxy reverso | URL Map do Load Balancer: `/` → frontend, `/api/*` → backend |
| Banco gerenciado/serverless | Firestore Enterprise com compatibilidade MongoDB |
| Banco sem acesso público | Sem IP exposto; acessado só pela identidade de serviço do backend, via IAM/OIDC |
| Controle de acesso do banco | Papel IAM `roles/datastore.user` concedido apenas à Service Account do backend |
| CI/CD a partir do GitHub | Cloud Build (2nd gen) conectado ao repositório, com deploy automático no Cloud Run a cada push na `main` |

---

## 4. Segurança por camada

| Componente | Quem acessa | Quem NÃO acessa | Porta/Protocolo | Observação |
|---|---|---|---|---|
| Load Balancer | Qualquer usuário da internet | — | 443 (HTTPS) / 80 redireciona para 443 | Ponto de entrada único e público |
| Frontend (Cloud Run) | Somente o Load Balancer (via Serverless NEG) | Acesso direto pela URL `run.app` não é o caminho pretendido | 8080 interno do Cloud Run | Serve os arquivos estáticos da SPA |
| Backend (Cloud Run) | Somente o Load Balancer, no caminho `/api/*` | Internet direta — bloqueado por `internal-and-cloud-load-balancing` | 5000 interno do Cloud Run | Não possui IP público navegável |
| Firestore (banco) | Somente a Service Account do backend | Frontend, internet, qualquer outra identidade | API HTTPS gerenciada pelo Google | Sem IP público; autenticação via IAM/OIDC, não por usuário/senha em variável de ambiente |

Nenhuma credencial de banco, chave de API ou token fica versionada no repositório — os identificadores de conexão com o Firestore são passados como variáveis de ambiente pelo próprio pipeline de deploy, e a autenticação do backend usa a identidade da Service Account do Cloud Run (sem chaves JSON).

---

## 5. CI/CD

```text
git push origin main
        |
        v
Cloud Build Connection (2nd gen, GitHub)
        |
        v
Cloud Build Trigger (um por serviço)
        |
        +--> docker build
        +--> push para o Artifact Registry
        +--> gcloud run deploy (Cloud Run)
```

Três triggers monitoram a branch `main`:
- `triodelicia-backend-main`
- `triodelicia-frontend-sae1-main`
- `triodelicia-frontend-saw1-main`

Não há push manual de imagem — o Artifact Registry é usado apenas internamente pelo pipeline.

---

## 6. Status atual (o que já foi alcançado)

- [x] Projeto GCP dedicado (`triodelicia-mensal2-2026`) criado do zero
- [x] Firestore Enterprise com compatibilidade MongoDB provisionado
- [x] Service Accounts dedicadas para backend, frontend e Cloud Build, com permissões mínimas necessárias (princípio do menor privilégio)
- [x] Conexão do GitHub via Cloud Build (2nd gen) configurada e autorizada
- [x] Três triggers de build/deploy criados e testados com sucesso (build + deploy automático confirmado nos logs)
- [x] Os três serviços Cloud Run (backend + 2 frontends) publicados e respondendo
- [x] Serverless NEGs, Backend Services e URL Map do Load Balancer configurados (proxy reverso `/api/*` → backend)
- [x] IP público global reservado e DNS (`triodelicia.duckdns.org`) apontado para ele
- [x] Certificado HTTPS gerenciado pelo Google emitido para o domínio
- [x] Testes funcionais da API pelo domínio (`GET`/`POST` em `/api/todos`) validados via PowerShell
- [ ] Evidências finais (prints/vídeo) de todos os testes obrigatórios do enunciado, incluindo a demonstração de bloqueio de acesso direto ao backend e ao banco, e o teste de redundância (queda de uma das instâncias de frontend)
- [ ] Documentação curta final de entrega (este README cobre a arquitetura; falta o texto específico de entrega pedido no item 8 do enunciado)

---

## 7. Rodando localmente (desenvolvimento)

```bash
docker compose up --build
```

O `docker-compose.yaml` sobe frontend, backend e um MongoDB local — usado **somente em desenvolvimento**. Em produção, o banco é substituído pelo Firestore com compatibilidade MongoDB, sem alterar o código do backend (Mongoose continua funcionando normalmente).

---

## 8. Créditos

- Base da aplicação: fork adaptado de [`LaercioMLB/aula-uniamerica-infraestrutura-cloud`](https://github.com/LaercioMLB/aula-uniamerica-infraestrutura-cloud)
- Atividade: Mensal 2 — Infraestrutura Cloud, Uniamérica
- Grupo: **Triodelicia**