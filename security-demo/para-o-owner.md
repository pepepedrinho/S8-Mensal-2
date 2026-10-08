# Para o owner do projeto — 3 concessões de IAM

> ## ⚠️ Resolvido por outro caminho — e isso é uma limitação registrada
>
> **Em 08/10/2026 nada disto foi executado.** Em vez das três concessões por recurso,
> o owner trocou o papel de `Lipe31102005@gmail.com` de `roles/editor` para
> **`roles/owner`** no projeto. Com isso as etapas 4 e 6 do `01-setup.sh` rodaram
> direto (evidência em `evidencias/03-setup.txt`) e os comandos abaixo deixaram de
> ser necessários.
>
> **Por que isso é uma limitação, e não a solução:**
>
> - `roles/owner` é uma **role básica**, o que a regra 3 do `CLAUDE.md` proíbe
>   justamente por ser ampla demais. Ela dá acesso a **todo** secret e **toda** chave
>   do projeto, mais tudo o mais — em vez de só ao secret `APP_API_KEY` e à chave
>   `seminario-chave`, que é o que a tarefa exigia.
> - É exatamente o anti-padrão que o cenário **S8** existe para demonstrar: uma role
>   ampla concedida em nível alto anula o controle feito no recurso. A diferença é que
>   aqui ela está na **conta humana que opera a demo**, não na service account do
>   backend. O `00-check.sh` não detecta isso, porque ele audita as roles da SA do
>   backend, não as do operador.
> - A concessão é **temporária, só para viabilizar o seminário**, e **deve ser
>   revertida para `roles/editor` depois** — ver a seção 6 no fim deste documento.
>
> O que **não** mudou: a service account do backend continua com menor privilégio
> correto — `roles/datastore.user` no projeto, e `secretAccessor` / 
> `cryptoKeyEncrypterDecrypter` concedidos **no secret e na chave**, nunca no projeto.
> O problema é só o papel da conta humana.
>
> Os comandos abaixo seguem válidos e são o **caminho preferível** se o papel voltar
> a ser `editor` e o seminário precisar ser remontado.

**Para:** `pedrohalvesdosantos@gmail.com` (owner de `triodelicia-mensal2-2026`)
**Assunto:** liberar o seminário de Cloud IAM / Secret Manager / Cloud KMS para
`Lipe31102005@gmail.com`

## Por que isso é necessário

*(Este era o quadro quando o documento foi escrito, com a conta em `roles/editor`.
Vale de novo assim que a reversão da seção 6 for feita.)*

Com `roles/editor`, a conta `Lipe31102005@gmail.com` **cria** secret, key ring e chave,
mas **não altera a política IAM de nenhum deles** — essa role não inclui
`secretmanager.secrets.setIamPolicy` nem `cloudkms.cryptoKeys.setIamPolicy`.

Resultado: os recursos do seminário existem, mas a service account do backend não tem
acesso a eles, e os cenários de erro S1 e S5 (que removem e recolocam esses acessos)
não podem ser executados.

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

> Esta seção só se aplica **se as concessões 1 a 3 tiverem sido executadas**. No
> caminho que foi seguido em 08/10/2026 elas não foram — pule para a seção 6.

As roles 1 e 2 podem ficar enquanto o seminário existir. A **3** é a que vale remover,
porque permite assumir outra identidade:

```bash
gcloud iam service-accounts remove-iam-policy-binding \
  seminario-sem-acesso@triodelicia-mensal2-2026.iam.gserviceaccount.com \
  --project=triodelicia-mensal2-2026 \
  --member="user:Lipe31102005@gmail.com" \
  --role="roles/iam.serviceAccountTokenCreator"
```

> **Importante:** `roles/editor` não tem `iam.serviceAccounts.setIamPolicy`, então
> **depois da reversão da seção 6** a conta `Lipe31102005@gmail.com` deixa de conseguir
> remover esse binding sozinha, e o `simulate-errors.sh restore` passa a reportar falha
> nesse item específico — esperado, e a remoção precisa sair daqui. Enquanto ela estiver
> com `roles/owner`, consegue fazer tudo (é precisamente o excesso de privilégio
> apontado no aviso do topo).

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

## 6. Depois do seminário — reverter `roles/owner` para `roles/editor`

**Esta é a pendência aberta do caminho que foi seguido.** Enquanto não for feita, uma
conta humana segue com role básica ampla no projeto, contrariando a regra 3 do
`CLAUDE.md`.

Devolver o papel anterior:

```bash
gcloud projects add-iam-policy-binding triodelicia-mensal2-2026 \
  --member="user:Lipe31102005@gmail.com" \
  --role="roles/editor" \
  --condition=None
```

Depois retirar o `owner`:

```bash
gcloud projects remove-iam-policy-binding triodelicia-mensal2-2026 \
  --member="user:Lipe31102005@gmail.com" \
  --role="roles/owner" \
  --condition=None
```

> **A ordem importa.** Conceder o `editor` primeiro e só depois remover o `owner`; na
> ordem inversa existe uma janela em que a conta fica sem nenhuma permissão no projeto.
> Foi o que aconteceu na troca de 08/10/2026 e durou cerca de 2 minutos, com todo
> comando `gcloud` retornando `PERMISSION_DENIED` nesse intervalo. O IAM propaga em
> segundos a minutos, então conceder antes de remover evita o buraco.

Conferir o resultado — deve listar `roles/editor` e **não** `roles/owner`:

```bash
gcloud projects get-iam-policy triodelicia-mensal2-2026 \
  --flatten='bindings[].members' \
  --format='value(bindings.role,bindings.members)' \
  | grep -i 'lipe31102005'
```

Se o seminário ainda for ser remontado depois disso, aí sim valem as concessões 1 a 3
do início deste documento — elas dão exatamente o necessário, no recurso, sem role
básica.

---

## Opcional — cenário S8 (exige alterar a política do PROJETO)

O S8 é o cenário que demonstra o erro mais importante do seminário: **políticas de
permissão do IAM são aditivas e herdadas**, então uma role concedida no **projeto**
anula o controle feito no recurso. Ele concede `roles/secretmanager.secretAccessor`
à SA do backend **no projeto**, remove o binding equivalente **no secret**, e mostra
que o endpoint continua respondendo `200` — a SA passa a ler esse e **todos os outros
secrets do projeto**.

Isso exige `resourcemanager.projects.setIamPolicy`, que `roles/editor` **não tem**.

- **Enquanto `Lipe31102005@gmail.com` estiver com `roles/owner`,** ela consegue rodar
  o S8 sozinha — o `simulate-errors.sh` já executa os passos abaixo, com confirmação
  a cada comando, e restaura na ordem correta no fim.
- **Depois da reversão da seção 6,** volta a depender de você, e o S8 passa a ser
  opcional: os outros oito cenários não dependem dele.

Em qualquer dos casos, os comandos são estes — úteis como referência e para conferir
o que o script faz:

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
