# Evidência 01 — Segredos no código (slide 7: antes e depois)

Busca por credenciais escritas em código ou configuração, na árvore de trabalho e em todo o
histórico do git. Gerada com:

```bash
bash security-demo/buscar-credenciais.sh "<título>" >> security-demo/evidencias/01-segredos-no-codigo.md
```

Todos os valores literais aparecem mascarados (`***`). Os valores encontrados são comparados só
por hash dentro do script e nunca são exibidos. No "Antes", as únicas alterações não commitadas
eram o `CLAUDE.md` e o próprio diretório `security-demo/`.

## Antes

- Data da busca: 2026-10-08 11:58
- HEAD: `7333d6d` — alterações não commitadas na árvore: sim
- Padrões: URI com `usuário:senha@`; `password/secret/api_key/token = valor`;
  chave privada PEM; API key do Google (`AIza…`); token do GitHub (`ghp_…`).
- Fora da busca: `security-demo/` (este script e as evidências) e `package-lock.json`.

### Árvore de trabalho (versionados + novos não ignorados)

| Arquivo | Linha | Trecho (mascarado) | Classificação |
|---|---|---|---|
| `backend/index.js` | 16 | `` : "mongodb://root:***@mongo-todo:27017/todo-app?authSource=admin"); `` | **valor literal** |
| `banco-de-dados/docker-compose.yml` | 13 | `` - MONGO_INITDB_ROOT_PASSWORD=*** `` | **valor literal** |
| `docker-compose.yaml` | 34 | `` - MONGO_INITDB_ROOT_PASSWORD=*** `` | **valor literal** |

### Arquivos .env presentes no disco e ignorados pelo git (só nomes)

Nenhum.

### Histórico do git (17 commits, todas as refs)

| Arquivo | Linha* | Trecho (mascarado) | Commits em que aparece (mais recente → mais antigo) |
|---|---|---|---|
| `backend/index.js` | 16 | `` : "mongodb://root:***@mongo-todo:27017/todo-app?authSource=admin"); `` | 7333d6d, 355ca70, a695a82, c0c4f35 |
| `banco-de-dados/docker-compose.yml` | 13 | `` - MONGO_INITDB_ROOT_PASSWORD=*** `` | 7333d6d, 355ca70, a695a82, c0c4f35, dabc9ae, b2e1fec, 7a81c41, 97a8395, df091da, 8487b10, 88e7140, 5655ed5, b29e93c |
| `docker-compose.yaml` | 34 | `` - MONGO_INITDB_ROOT_PASSWORD=*** `` | 7333d6d, 355ca70, a695a82, c0c4f35, dabc9ae, b2e1fec, 7a81c41 |
| `backend/index.js` | 21 | `` : 'mongodb://root:***@mongo-todo:27017/todo-app?authSource=admin'); `` | dabc9ae, b2e1fec |
| `backend/index.js` | 11 | `` mongoose.connect('mongodb://root:***@mongo-todo:27017/todo-app?authSource=admin', { `` | 7a81c41 |
| `backend/index.js` | 11 | `` mongoose.connect('mongodb://root:***@localhost:27017/todo-app?authSource=admin', { `` | 97a8395, df091da, 8487b10 |

\* Linha no commit mais recente em que o trecho aparece.

### Resumo

- Ocorrências com valor literal na árvore de trabalho: **3**
- Valores literais distintos na árvore, sem contar `.env.example` (comparados por hash, não exibidos): 1
- Valores literais distintos no histórico (comparados por hash, não exibidos): 1


---

## Depois

- Data da busca: 2026-10-08 12:04
- HEAD: `7333d6d` — alterações não commitadas na árvore: sim
- Padrões: URI com `usuário:senha@`; `password/secret/api_key/token = valor`;
  chave privada PEM; API key do Google (`AIza…`); token do GitHub (`ghp_…`).
- Fora da busca: `security-demo/` (este script e as evidências) e `package-lock.json`.

### Árvore de trabalho (versionados + novos não ignorados)

| Arquivo | Linha | Trecho (mascarado) | Classificação |
|---|---|---|---|
| `.env.example` | 7 | `` #   sed -i "s/^MONGO_ROOT_PASSWORD=*** rand -hex 24)/" .env `` | exemplo (valor falso) |
| `.env.example` | 21 | `` MONGO_ROOT_PASSWORD=*** `` | exemplo (valor falso) |
| `banco-de-dados/docker-compose.yml` | 13 | `` - MONGO_INITDB_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD:?defina MONGO_ROOT_PASSWORD no .env (veja .env.example)} `` | referência a variável |
| `docker-compose.yaml` | 27 | `` - MONGO_URI=mongodb://${MONGO_ROOT_USERNAME}:${MONGO_ROOT_PASSWORD}@mongo-todo:27017/todo-app?authSource=admin `` | referência a variável |
| `docker-compose.yaml` | 39 | `` - MONGO_INITDB_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD:?defina MONGO_ROOT_PASSWORD no .env (veja .env.example)} `` | referência a variável |

### Arquivos .env presentes no disco e ignorados pelo git (só nomes)

Nenhum.

### Histórico do git (17 commits, todas as refs)

| Arquivo | Linha* | Trecho (mascarado) | Commits em que aparece (mais recente → mais antigo) |
|---|---|---|---|
| `backend/index.js` | 16 | `` : "mongodb://root:***@mongo-todo:27017/todo-app?authSource=admin"); `` | 7333d6d, 355ca70, a695a82, c0c4f35 |
| `banco-de-dados/docker-compose.yml` | 13 | `` - MONGO_INITDB_ROOT_PASSWORD=*** `` | 7333d6d, 355ca70, a695a82, c0c4f35, dabc9ae, b2e1fec, 7a81c41, 97a8395, df091da, 8487b10, 88e7140, 5655ed5, b29e93c |
| `docker-compose.yaml` | 34 | `` - MONGO_INITDB_ROOT_PASSWORD=*** `` | 7333d6d, 355ca70, a695a82, c0c4f35, dabc9ae, b2e1fec, 7a81c41 |
| `backend/index.js` | 21 | `` : 'mongodb://root:***@mongo-todo:27017/todo-app?authSource=admin'); `` | dabc9ae, b2e1fec |
| `backend/index.js` | 11 | `` mongoose.connect('mongodb://root:***@mongo-todo:27017/todo-app?authSource=admin', { `` | 7a81c41 |
| `backend/index.js` | 11 | `` mongoose.connect('mongodb://root:***@localhost:27017/todo-app?authSource=admin', { `` | 97a8395, df091da, 8487b10 |

\* Linha no commit mais recente em que o trecho aparece.

### Resumo

- Ocorrências com valor literal na árvore de trabalho: **0**
- Valores literais distintos na árvore, sem contar `.env.example` (comparados por hash, não exibidos): 0
- Valores literais distintos no histórico (comparados por hash, não exibidos): 1

### Nota sobre o histórico do git

A senha removida continua acessível nos 13 commits listados acima, já publicados no GitHub:
apagar do HEAD não apaga do histórico, nem de clones e forks existentes. Por ser só a senha do
root de um MongoDB local e descartável, a decisão foi não reescrever o histórico e tratar o valor
como queimado (nunca reutilizar). Com uma credencial real, a ordem seria: 1) revogar ou rotacionar
na origem imediatamente, porque o vazamento já aconteceu; 2) guardar o novo valor no Secret
Manager, com acesso concedido por IAM no próprio secret; 3) só então, se necessário, limpar o
histórico (`git filter-repo` + push forçado), sabendo que cópias antigas continuam com o valor.
