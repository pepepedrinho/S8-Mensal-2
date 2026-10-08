#!/usr/bin/env bash
# Seminário Cloud IAM, Secret Manager e Cloud KMS — Triodelícia
# Slides 6 a 10 e slide 12, passos 2, 3 e 5 (mapa de cada etapa nos comentários abaixo).
# Monta Secret Manager + Cloud KMS com menor privilégio (roles concedidas NO secret e
# NA chave, nunca no projeto).
#
# Idempotente: cada etapa verifica o estado atual e só altera o que falta.
# Cada comando que altera algo é exibido e só roda após confirmação (s/N); recusar
# encerra o script, porque as etapas seguintes dependem da anterior.
# O valor do secret é gerado e enviado por pipe direto ao gcloud: nunca é exibido,
# salvo em variável ou gravado em arquivo.
#
# Uso (Git Bash):
#   bash security-demo/01-setup.sh
#   bash security-demo/01-setup.sh --sem-iam
#
# --sem-iam pula as etapas 4 e 6, que concedem as roles NO SECRET e NA CHAVE. Serve
# para quem cria os recursos mas não tem setIamPolicy neles (roles/editor, por
# exemplo, cria secret e chave mas não altera a política de nenhum dos dois). As
# etapas 4 e 6 ficam listadas como pendentes no fim; quem tiver permissão as executa
# depois — veja security-demo/para-o-owner.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

uso() {
  cat <<'FIM_USO'
Uso: bash security-demo/01-setup.sh [--sem-iam]

  (sem opção)  monta tudo: APIs, secret, primeira versão, key ring, chave e as
               roles da SA do backend no secret e na chave.
  --sem-iam    pula as etapas 4 e 6 (as concessões de IAM no secret e na chave) e
               lista no fim o que ficou pendente. Para quem cria os recursos mas
               não tem setIamPolicy neles.
  -h, --help   esta mensagem.
FIM_USO
}

# O parse vem antes de carregar o config.sh: ele consulta o GCP, e --help/opção
# inválida não devem depender de rede nem de credencial.
SEM_IAM=0
for arg in "$@"; do
  case "$arg" in
    --sem-iam) SEM_IAM=1 ;;
    -h|--help) uso; exit 0 ;;
    *)
      echo "Opção desconhecida: $arg" >&2
      echo >&2
      uso >&2
      exit 2 ;;
  esac
done

# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# Etapas de IAM que o --sem-iam deixou para trás (texto exibido no fim).
PENDENTES=()

if [ -t 1 ]; then
  VERMELHO=$'\033[1;31m'; NEGRITO=$'\033[1m'; RESET=$'\033[0m'
else
  VERMELHO=""; NEGRITO=""; RESET=""
fi

ROTACAO_DIAS=90
ROLE_SECRET="roles/secretmanager.secretAccessor"
ROLE_CHAVE="roles/cloudkms.cryptoKeyEncrypterDecrypter"
MEMBRO="serviceAccount:$BACKEND_SA"

etapa()  { printf '\n%s== %s ==%s\n' "$NEGRITO" "$1" "$RESET"; }
ja_ok()  { printf '  [ok] %s — nada a fazer.\n' "$1"; }
alerta() { printf '  %s[ALERTA] %s%s\n' "$VERMELHO" "$1" "$RESET"; }
pulado() { printf '  [--sem-iam] etapa pulada: %s\n' "$1"; PENDENTES+=("$2"); }

# gcloud sem o \r do Windows.
gc() { gcloud "$@" | tr -d '\r'; }

# Mostra o comando exato e pede confirmação; qualquer resposta diferente de "s" encerra.
confirmar() {
  printf '\n  Comando:\n    %s\n' "$1"
  local resposta=""
  read -r -p "  Executar? [s/N] " resposta || true
  case "$resposta" in
    s|S|sim|Sim|SIM) return 0 ;;
  esac
  echo "  Cancelado. Nenhuma etapa seguinte foi executada."
  exit 1
}

# Comando sem pipe: o texto exibido é gerado dos mesmos argumentos que serão executados.
rodar() {
  confirmar "$(printf '%q ' "$@")"
  "$@"
}

# Política IAM achatada ("role<TAB>membro") contém o par?
politica_tem() { grep -qxF "$2"$'\t'"$3" <<< "$1"; }

# ---------------------------------------------------------------------------------------
etapa "0. Contexto"
echo "  Projeto: $PROJECT_ID | Região: $REGION"
echo "  SA do backend ($BACKEND_SERVICE): $BACKEND_SA"
if [[ "$BACKEND_SA" == *"$COMPUTE_DEFAULT_SA_SUFFIX" ]]; then
  alerta "a SA do backend é a conta PADRÃO do Compute. Dar acesso ao secret e à chave para ela"
  alerta "libera esse acesso a todo serviço que use a conta padrão. O ideal é criar uma SA dedicada antes."
  confirmar "(continuar a configuração usando a conta padrão do Compute)"
fi

# ---------------------------------------------------------------------------------------
etapa "1. APIs do Secret Manager e do Cloud KMS"
HABILITADAS="$(gc services list --enabled --project="$PROJECT_ID" --format='value(config.name)')"
FALTANDO=()
for api in secretmanager.googleapis.com cloudkms.googleapis.com; do
  if grep -qx "$api" <<< "$HABILITADAS"; then
    ja_ok "$api já habilitada"
  else
    FALTANDO+=("$api")
  fi
done
if [ "${#FALTANDO[@]}" -gt 0 ]; then
  rodar gcloud services enable "${FALTANDO[@]}" --project="$PROJECT_ID"
fi

# ---------------------------------------------------------------------------------------
# Slide 7 e slide 12, passo 2: criar o secret.
etapa "2. Secret $SECRET_NAME (replicação user-managed em $REGION)"
if gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  LOCAIS="$(gc secrets describe "$SECRET_NAME" --project="$PROJECT_ID" \
    --format='value(replication.userManaged.replicas[].location)')"
  if [ "$LOCAIS" = "$REGION" ]; then
    ja_ok "o secret já existe com replicação user-managed em $REGION"
  else
    alerta "o secret já existe com outra replicação (${LOCAIS:-automática}). A replicação não pode ser"
    alerta "alterada depois de criada; para corrigir, seria preciso apagar e recriar o secret."
  fi
else
  rodar gcloud secrets create "$SECRET_NAME" --project="$PROJECT_ID" \
    --replication-policy=user-managed --locations="$REGION" \
    --labels=app=triodelicia,uso=seminario
fi

# ---------------------------------------------------------------------------------------
# Slide 7 (versões v1/v2/v3) e slide 12, passo 2: primeira versão do secret.
etapa "3. Versão do secret (valor aleatório, nunca exibido)"
ATIVAS="$(gc secrets versions list "$SECRET_NAME" --project="$PROJECT_ID" \
  --filter='state=ENABLED' --format='value(name)' | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$ATIVAS" -gt 0 ]; then
  ja_ok "o secret já tem $ATIVAS versão(ões) ativa(s); para rotacionar, adicione outra versão de propósito"
else
  # tr -d '\n': o openssl termina a saída com quebra de linha, que viraria parte do segredo.
  confirmar "openssl rand -base64 32 | tr -d '\\n' | gcloud secrets versions add $SECRET_NAME --project=$PROJECT_ID --data-file=-"
  openssl rand -base64 32 | tr -d '\n' \
    | gcloud secrets versions add "$SECRET_NAME" --project="$PROJECT_ID" --data-file=-
fi

# ---------------------------------------------------------------------------------------
# Slides 6 e 8 e slide 12, passo 3: conceder acesso via IAM, só no secret.
etapa "4. $ROLE_SECRET para a SA do backend SOMENTE no secret"
POL_SECRET="$(gc secrets get-iam-policy "$SECRET_NAME" --project="$PROJECT_ID" \
  --flatten='bindings[].members' --format='value(bindings.role,bindings.members)')"
if politica_tem "$POL_SECRET" "$ROLE_SECRET" "$MEMBRO"; then
  ja_ok "a SA do backend já tem $ROLE_SECRET no secret"
elif [ "$SEM_IAM" -eq 1 ]; then
  # Ler a política é permitido a quem não pode alterá-la, então a checagem acima roda
  # sempre: com --sem-iam só se pula a escrita, e nada é marcado como pendente à toa.
  pulado "$ROLE_SECRET para a SA do backend no secret $SECRET_NAME" \
    "$(printf 'gcloud secrets add-iam-policy-binding %s --project=%s \\\n    --member="%s" --role="%s"' \
       "$SECRET_NAME" "$PROJECT_ID" "$MEMBRO" "$ROLE_SECRET")"
else
  rodar gcloud secrets add-iam-policy-binding "$SECRET_NAME" --project="$PROJECT_ID" \
    --member="$MEMBRO" --role="$ROLE_SECRET" --format=none
fi

# ---------------------------------------------------------------------------------------
# Slide 9 (Key Ring → Crypto Key → versões) e slide 12, passo 5: criar a Crypto Key.
etapa "5. Key ring $KEYRING e chave $KEY (encryption, rotação a cada $ROTACAO_DIAS dias)"
if gcloud kms keyrings describe "$KEYRING" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  ja_ok "o key ring já existe"
else
  echo "  Atenção: key rings e chaves do Cloud KMS NÃO podem ser apagados (só as versões da chave"
  echo "  podem ser destruídas). Confira os nomes no config.sh antes de confirmar."
  rodar gcloud kms keyrings create "$KEYRING" --location="$REGION" --project="$PROJECT_ID"
fi

PROXIMA_ROTACAO="$(date -u -d "+${ROTACAO_DIAS} days" '+%Y-%m-%dT%H:%M:%SZ')"
if gcloud kms keys describe "$KEY" --keyring="$KEYRING" --location="$REGION" \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  IFS='|' read -r PROPOSITO PERIODO <<< "$(gc kms keys describe "$KEY" --keyring="$KEYRING" \
    --location="$REGION" --project="$PROJECT_ID" --format='value[separator="|"](purpose,rotationPeriod)')"
  if [ "$PROPOSITO" != "ENCRYPT_DECRYPT" ]; then
    alerta "a chave já existe com purpose=$PROPOSITO (esperado ENCRYPT_DECRYPT). O purpose não pode"
    alerta "ser alterado: use outro nome em KEY no config.sh."
    exit 1
  fi
  if [ "${PERIODO:-}" = "$((ROTACAO_DIAS * 86400))s" ]; then
    ja_ok "a chave já existe (encryption, rotação a cada $ROTACAO_DIAS dias)"
  else
    echo "  A chave existe, mas a rotação atual é '${PERIODO:-nenhuma}'."
    rodar gcloud kms keys update "$KEY" --keyring="$KEYRING" --location="$REGION" \
      --project="$PROJECT_ID" --rotation-period="${ROTACAO_DIAS}d" --next-rotation-time="$PROXIMA_ROTACAO"
  fi
else
  rodar gcloud kms keys create "$KEY" --keyring="$KEYRING" --location="$REGION" \
    --project="$PROJECT_ID" --purpose=encryption \
    --rotation-period="${ROTACAO_DIAS}d" --next-rotation-time="$PROXIMA_ROTACAO"
fi

# ---------------------------------------------------------------------------------------
# Slide 10: permissão de cifrar e decifrar, só na chave.
etapa "6. $ROLE_CHAVE para a SA do backend SOMENTE na chave"
POL_CHAVE="$(gc kms keys get-iam-policy "$KEY" --keyring="$KEYRING" --location="$REGION" \
  --project="$PROJECT_ID" --flatten='bindings[].members' --format='value(bindings.role,bindings.members)')"
if politica_tem "$POL_CHAVE" "$ROLE_CHAVE" "$MEMBRO"; then
  ja_ok "a SA do backend já tem $ROLE_CHAVE na chave"
elif [ "$SEM_IAM" -eq 1 ]; then
  pulado "$ROLE_CHAVE para a SA do backend na chave $KEY" \
    "$(printf 'gcloud kms keys add-iam-policy-binding %s --keyring=%s --location=%s \\\n    --project=%s --member="%s" --role="%s"' \
       "$KEY" "$KEYRING" "$REGION" "$PROJECT_ID" "$MEMBRO" "$ROLE_CHAVE")"
else
  rodar gcloud kms keys add-iam-policy-binding "$KEY" --keyring="$KEYRING" --location="$REGION" \
    --project="$PROJECT_ID" --member="$MEMBRO" --role="$ROLE_CHAVE" --format=none
fi

# ---------------------------------------------------------------------------------------
etapa "7. Verificação final (00-check.sh)"
bash "$SCRIPT_DIR/00-check.sh"

# ---------------------------------------------------------------------------------------
if [ "${#PENDENTES[@]}" -gt 0 ]; then
  etapa "PENDENTE: ${#PENDENTES[@]} concessão(ões) de IAM não executada(s) (--sem-iam)"
  alerta "Os recursos existem, mas a SA do backend AINDA NÃO TEM acesso a eles."
  alerta "Enquanto isso não for feito, /api/security responde 403 e os cenários S1 e S5"
  alerta "não têm o que remover (o 00-check.sh acima mostra os avisos correspondentes)."
  echo
  echo "  Quem tiver setIamPolicy nos recursos precisa rodar:"
  for cmd in "${PENDENTES[@]}"; do
    printf '\n    %s\n' "$cmd"
  done
  echo
  echo "  Os comandos prontos para colar, com explicação, estão em:"
  echo "    security-demo/para-o-owner.md"
fi
