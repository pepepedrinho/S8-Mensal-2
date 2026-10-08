# CLAUDE.md — Triodelícia (seminário Cloud IAM, Secret Manager e Cloud KMS)

## Contexto

- App: frontend React (nginx) + backend Node/Express/Mongoose, ambos no Cloud Run.
- Banco: Firestore Enterprise com compatibilidade MongoDB, autenticação `MONGODB-OIDC`.
- Entrada: Global External HTTPS Load Balancer em `triodelicia.duckdns.org`.
- Projeto GCP: `triodelicia-mensal2-2026` — região `southamerica-east1`.
- Serviço do backend: `triodelicia-backend`.

## Regras (valem para toda a sessão)

1. **Nunca exibir material sensível.** Não imprimir valor de segredo, ciphertext completo,
   token ou connection string em log, resposta HTTP, commit, arquivo ou terminal. Ao
   inspecionar algo que possa conter um desses valores, mascarar antes de exibir (ex.: `***`)
   ou mostrar só metadados (nome, versão, tamanho, hash curto).
2. **gcloud que muda estado exige confirmação.** Antes de qualquer comando `gcloud` que crie,
   altere ou remova recurso ou política IAM, mostrar o comando exato e esperar confirmação.
   Comandos só de leitura (`describe`, `list`, `get-iam-policy`, etc.) podem rodar direto.
3. **Menor privilégio.** Nunca usar roles básicas (`roles/owner`, `roles/editor`,
   `roles/viewer`). Conceder roles no recurso (secret, chave KMS), não no projeto — exceto
   quando o usuário pedir explicitamente para simular o erro.
4. **Logs do backend.** Manter o padrão de `backend/logger.js`: uma linha JSON por evento em
   stdout, sem dados sensíveis (senha, token, connection string, JWT, cookie, texto da tarefa,
   dados pessoais). Em erros, registrar só o tipo (`err.name`), nunca o objeto/mensagem inteira.
5. **Commits em português.**
6. **Scripts em `security-demo/`** são bash e devem funcionar no Git Bash do Windows. O caminho
   do repositório tem espaços: sempre usar aspas em variáveis de caminho (`"$REPO_DIR"`,
   `"$(dirname "$0")"`, etc.).
