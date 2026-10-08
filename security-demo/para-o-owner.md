# Para o owner do projeto — 3 concessões de IAM

**Para:** `pedrohalvesdosantos@gmail.com` (owner de `triodelicia-mensal2-2026`)
**Assunto:** liberar o seminário de Cloud IAM / Secret Manager / Cloud KMS para
`Lipe31102005@gmail.com`

## Por que isso é necessário

A conta `Lipe31102005@gmail.com` tem `roles/editor` no projeto. Essa role **cria**
secret, key ring e chave, mas **não altera a política IAM de nenhum deles** — não
inclui `secretmanager.secrets.setIamPolicy` nem `cloudkms.cryptoKeys.setIamPolicy`.

Resultado: os recursos do seminário já existem, mas a service account do backend ainda
não tem acesso a eles, e os cenários de erro S1 e S5 (que removem e recolocam esses
acessos) não podem ser executados.

São **3 comandos**, todos concedendo **no recurso específico**, nenhum no projeto.
Nada aqui dá acesso amplo: cada role vale só para um secret, uma chave e uma service
account.

## Antes de começar

Os recursos abaixo já devem existir (foram criados com a conta `editor`). Se algum
comando reclamar que não existe, pare e avise.

| Recurso | Nome |
|---|---|
| Secret | `APP_API_KEY` |
| Key ring | `seminario-seguranca` (região `southamerica-east1`) |
| Chave | `seminario-chave` |
| SA vazia do cenário S9 | `seminario-sem-acesso@triodelicia-mensal2-2026.iam.gserviceaccount.com` |

Abra o **Cloud Shell** no projeto `triodelicia-mensal2-2026` e cole os comandos na
ordem. Cada um é independente e pode ser repetido sem efeito colateral.

---

## 1. Acesso de IAM ao secret `APP_API_KEY`

Permite gerenciar **quem** pode ler esse secret — e só esse. É o que habilita o
cenário S1 (remover e recolocar o `secretAccessor` da SA do backend).

```bash
gcloud secrets add-iam-policy-binding APP_API_KEY \
  --project=triodelicia-mensal2-2026 \
  --member="user:Lipe31102005@gmail.com" \
  --role="roles/secretmanager.admin"
```

> Nota: `roles/secretmanager.admin` inclui `secretmanager.versions.access`, ou seja,
> também permite **ler o valor** do secret. Não existe role predefinida que dê
> `setIamPolicy` sem isso, e o valor é um `openssl rand` descartável criado só para o
> seminário — nenhuma credencial real. O escopo continua sendo apenas este secret.

## 2. Acesso de IAM à chave `seminario-chave`

Permite gerenciar **quem** pode usar essa chave — e só ela. Habilita o cenário S5
(remover e recolocar o `cryptoKeyEncrypterDecrypter` da SA do backend).

```bash
gcloud kms keys add-iam-policy-binding seminario-chave \
  --keyring=seminario-seguranca \
  --location=southamerica-east1 \
  --project=triodelicia-mensal2-2026 \
  --member="user:Lipe31102005@gmail.com" \
  --role="roles/cloudkms.admin"
```

> `roles/cloudkms.admin` **não** inclui cifrar nem decifrar (`useToEncrypt` /
> `useToDecrypt`) — é só administração da chave. Essa separação é proposital no Cloud
> KMS e vira um slide do seminário.

## 3. Permissão de impersonar a SA vazia `seminario-sem-acesso`

Habilita o cenário S9: tentar ler o secret assumindo a identidade de uma service
account que não tem nenhuma role, para mostrar o `PERMISSION_DENIED`. A role é
concedida **naquela SA**, não no projeto — não permite impersonar nenhuma outra
identidade, inclusive a do backend.

```bash
gcloud iam service-accounts add-iam-policy-binding \
  seminario-sem-acesso@triodelicia-mensal2-2026.iam.gserviceaccount.com \
  --project=triodelicia-mensal2-2026 \
  --member="user:Lipe31102005@gmail.com" \
  --role="roles/iam.serviceAccountTokenCreator"
```

---

## 4. Verificação

Cada comando mostra a política do recurso. O esperado está logo abaixo de cada um.

```bash
gcloud secrets get-iam-policy APP_API_KEY \
  --project=triodelicia-mensal2-2026 \
  --flatten='bindings[].members' \
  --format='table(bindings.role,bindings.members)'
```
Esperado: uma linha `roles/secretmanager.admin` com `user:Lipe31102005@gmail.com`.

```bash
gcloud kms keys get-iam-policy seminario-chave \
  --keyring=seminario-seguranca \
  --location=southamerica-east1 \
  --project=triodelicia-mensal2-2026 \
  --flatten='bindings[].members' \
  --format='table(bindings.role,bindings.members)'
```
Esperado: uma linha `roles/cloudkms.admin` com `user:Lipe31102005@gmail.com`.

```bash
gcloud iam service-accounts get-iam-policy \
  seminario-sem-acesso@triodelicia-mensal2-2026.iam.gserviceaccount.com \
  --project=triodelicia-mensal2-2026 \
  --flatten='bindings[].members' \
  --format='table(bindings.role,bindings.members)'
```
Esperado: uma linha `roles/iam.serviceAccountTokenCreator` com
`user:Lipe31102005@gmail.com`.

Para confirmar que a SA do S9 continua **sem nenhuma role** no projeto (é o ponto do
cenário — ela precisa estar vazia), o resultado deste deve ser **vazio**:

```bash
gcloud projects get-iam-policy triodelicia-mensal2-2026 \
  --flatten='bindings[].members' \
  --format='value(bindings.role,bindings.members)' \
  | grep 'seminario-sem-acesso'
```

---

## 5. Depois do seminário — remover o acesso

As roles 1 e 2 podem ficar enquanto o seminário existir. A **3** é a que vale remover,
porque permite assumir outra identidade:

```bash
gcloud iam service-accounts remove-iam-policy-binding \
  seminario-sem-acesso@triodelicia-mensal2-2026.iam.gserviceaccount.com \
  --project=triodelicia-mensal2-2026 \
  --member="user:Lipe31102005@gmail.com" \
  --role="roles/iam.serviceAccountTokenCreator"
```

> **Importante:** `roles/editor` também não tem `iam.serviceAccounts.setIamPolicy`,
> então a conta `Lipe31102005@gmail.com` **não consegue remover** esse binding sozinha.
> O `simulate-errors.sh restore` vai reportar falha nesse item específico — é esperado,
> e a remoção precisa sair daqui. Os demais itens do restore (S1, S2, S5, S6) ela
> consegue fazer, depois das concessões 1 e 2.

Para remover as roles 1 e 2, se quiser:

```bash
gcloud secrets remove-iam-policy-binding APP_API_KEY \
  --project=triodelicia-mensal2-2026 \
  --member="user:Lipe31102005@gmail.com" \
  --role="roles/secretmanager.admin"

gcloud kms keys remove-iam-policy-binding seminario-chave \
  --keyring=seminario-seguranca --location=southamerica-east1 \
  --project=triodelicia-mensal2-2026 \
  --member="user:Lipe31102005@gmail.com" \
  --role="roles/cloudkms.admin"
```

---

## Opcional — cenário S8 (só você pode rodar)

O S8 é o cenário que demonstra o erro mais importante do seminário: **políticas de
permissão do IAM são aditivas e herdadas**, então uma role concedida no **projeto**
anula o controle feito no recurso. Ele concede `roles/secretmanager.secretAccessor`
à SA do backend **no projeto**, remove o binding equivalente **no secret**, e mostra
que o endpoint continua respondendo `200` — a SA passa a ler esse e **todos os outros
secrets do projeto**.

Isso exige `resourcemanager.projects.setIamPolicy`, que `roles/editor` não tem. Só o
owner pode executar, então **o S8 é opcional**: os outros oito cenários não dependem
dele.

Se quiser rodar, o roteiro é:

**a) conceder no projeto** (este é o comando "errado", de propósito):

```bash
gcloud projects add-iam-policy-binding triodelicia-mensal2-2026 \
  --member="serviceAccount:triodelicia-backend@triodelicia-mensal2-2026.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" \
  --condition=None
```

**b) remover no secret** — o controle que *deveria* bastar, e não basta:

```bash
gcloud secrets remove-iam-policy-binding APP_API_KEY \
  --project=triodelicia-mensal2-2026 \
  --member="serviceAccount:triodelicia-backend@triodelicia-mensal2-2026.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

Aguarde alguns minutos e confirme que `GET /api/security/secret` continua `200`. Esse
`200` é o resultado da demonstração.

**c) restaurar — nesta ordem, obrigatoriamente.** Primeiro recolocar no secret, só
depois remover do projeto; na ordem inversa existe uma janela em que o backend fica
sem acesso e a aplicação quebra:

```bash
gcloud secrets add-iam-policy-binding APP_API_KEY \
  --project=triodelicia-mensal2-2026 \
  --member="serviceAccount:triodelicia-backend@triodelicia-mensal2-2026.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

gcloud projects remove-iam-policy-binding triodelicia-mensal2-2026 \
  --member="serviceAccount:triodelicia-backend@triodelicia-mensal2-2026.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" \
  --condition=None
```

**Não deixe a role do passo (a) no projeto depois da demonstração.** Confirme que
saiu — este comando deve voltar **vazio**:

```bash
gcloud projects get-iam-policy triodelicia-mensal2-2026 \
  --flatten='bindings[].members' \
  --format='value(bindings.role,bindings.members)' \
  | grep 'secretmanager' | grep 'triodelicia-backend'
```
