#!/usr/bin/env bash
# Seminário Cloud IAM, Secret Manager e Cloud KMS — Triodelícia
# Slides 4 a 6 (IAM: Principal/Role/Permission/Resource, menor privilégio, arquitetura,
# exemplo da SA que recebe só o necessário) e slide 12, passo 1 (a SA do backend).
# Diagnóstico "antes" e "depois" (o 01-setup.sh chama este script no final).
#
# SOMENTE LEITURA: nenhum comando aqui cria, altera ou remove recurso ou política.
# Nunca exibe valor de secret nem de variável de ambiente: só nomes, estados e datas.
#
# Uso (Git Bash): bash security-demo/00-check.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

if [ -t 1 ]; then
  VERMELHO=$'\033[1;31m'; AMARELO=$'\033[33m'; VERDE=$'\033[32m'; NEGRITO=$'\033[1m'; RESET=$'\033[0m'
else
  VERMELHO=""; AMARELO=""; VERDE=""; NEGRITO=""; RESET=""
fi
ALERTAS=0

titulo() { printf '\n%s== %s ==%s\n' "$NEGRITO" "$1" "$RESET"; }
ok()     { printf '  %s[ok]%s %s\n' "$VERDE" "$RESET" "$1"; }
aviso()  { printf '  %s[!]%s %s\n' "$AMARELO" "$RESET" "$1"; }
alerta() { printf '  %s[ALERTA] %s%s\n' "$VERMELHO" "$1" "$RESET"; ALERTAS=$((ALERTAS + 1)); }
recuo()  { sed 's/^/    /'; }

# gcloud sem o \r do Windows.
gc() { gcloud "$@" | tr -d '\r'; }

# Permissões de uma role (predefinida ou custom), uma por linha.
permissoes_da_role() {
  local role="$1"
  case "$role" in
    projects/*/roles/*)
      gc iam roles describe "${role##*/}" --project="$(cut -d/ -f2 <<< "$role")" --format='value(includedPermissions)' ;;
    organizations/*/roles/*)
      gc iam roles describe "${role##*/}" --organization="$(cut -d/ -f2 <<< "$role")" --format='value(includedPermissions)' ;;
    *)
      gc iam roles describe "$role" --format='value(includedPermissions)' ;;
  esac | tr ';' '\n'
}

# ---------------------------------------------------------------------------------------
titulo "Contexto"
echo "  Projeto: $PROJECT_ID ($PROJECT_NUMBER) | Região: $REGION"
echo "  Conta ativa no gcloud: $(gc config get-value account 2>/dev/null)"

# ---------------------------------------------------------------------------------------
titulo "APIs"
HABILITADAS="$(gc services list --enabled --project="$PROJECT_ID" --format='value(config.name)')"
api_habilitada() { grep -qx "$1" <<< "$HABILITADAS"; }
for api in run.googleapis.com firestore.googleapis.com cloudbuild.googleapis.com \
           secretmanager.googleapis.com cloudkms.googleapis.com; do
  if api_habilitada "$api"; then ok "$api habilitada"; else aviso "$api NÃO habilitada"; fi
done

# ---------------------------------------------------------------------------------------
titulo "Service account do backend ($BACKEND_SERVICE)"
echo "  $BACKEND_SA"
if [[ "$BACKEND_SA" == *"$COMPUTE_DEFAULT_SA_SUFFIX" ]]; then
  alerta "é a conta PADRÃO do Compute: qualquer serviço sem --service-account usa a mesma identidade (e ela costuma ter roles/editor)."
else
  ok "SA dedicada (não é a conta padrão do Compute)"
fi

# ---------------------------------------------------------------------------------------
titulo "Service accounts de todos os serviços Cloud Run"
SERVICOS="$(gc run services list --project="$PROJECT_ID" \
  --format='value(metadata.name,spec.template.spec.serviceAccountName)')"
FRONTENDS=0
while IFS=$'\t' read -r nome sa; do
  [ -z "$nome" ] && continue
  [ -z "${sa:-}" ] && sa="${PROJECT_NUMBER}${COMPUTE_DEFAULT_SA_SUFFIX}"
  echo "  $nome -> $sa"
  [[ "$nome" == *frontend* ]] && FRONTENDS=$((FRONTENDS + 1))
  if [ "$nome" != "$BACKEND_SERVICE" ] && [ "$sa" = "$BACKEND_SA" ]; then
    alerta "$nome usa a MESMA SA do backend: herda acesso ao Firestore, ao secret e à chave."
  fi
done <<< "$SERVICOS"
if [ "$FRONTENDS" -eq 0 ]; then
  aviso "nenhum serviço com 'frontend' no nome. Se run/region estiver definido no gcloud config, a listagem fica restrita a essa região."
fi

# ---------------------------------------------------------------------------------------
titulo "Variáveis de ambiente do $BACKEND_SERVICE (só nomes, nunca valores)"
NOMES_ENV="$(gc run services describe "$BACKEND_SERVICE" --project="$PROJECT_ID" --region="$REGION" \
  --format='value(spec.template.spec.containers[0].env[].name)' | tr ';' '\n' | sed '/^$/d')"
if [ -z "$NOMES_ENV" ]; then
  echo "  (nenhuma)"
else
  recuo <<< "$NOMES_ENV"
fi
if grep -qx "MONGO_URI" <<< "$NOMES_ENV"; then
  alerta "MONGO_URI está definida no serviço: ela tem prioridade e ANULA a autenticação OIDC."
else
  ok "MONGO_URI não está definida (backend usa Firestore via OIDC)"
fi

# ---------------------------------------------------------------------------------------
titulo "Roles da SA do backend no PROJETO (herdadas por todo secret e chave do projeto)"
echo "  Obs.: só a política do projeto; herança de pasta/organização não é verificada aqui."
ROLES="$(gc projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' \
  --format='value(bindings.role,bindings.members,bindings.condition.title)' \
  | awk -F'\t' -v m="serviceAccount:$BACKEND_SA" '$2 == m { print $1 "\t" $3 }' | sort -u)"
if [ -z "$ROLES" ]; then
  ok "nenhuma role no projeto"
else
  while IFS=$'\t' read -r role condicao; do
    [ -z "$role" ] && continue
    echo "  - $role${condicao:+ (condição: $condicao)}"
    case "$role" in
      roles/owner|roles/editor|roles/viewer)
        alerta "$role é role BÁSICA: ampla demais para uma SA de runtime." ;;
    esac
    if ! PERMS="$(permissoes_da_role "$role" 2>/dev/null)"; then
      aviso "não foi possível ler as permissões de $role"
      continue
    fi
    SM="$(grep -c '^secretmanager\.' <<< "$PERMS" || true)"
    KMS="$(grep -c '^cloudkms\.' <<< "$PERMS" || true)"
    if [ "$SM" -gt 0 ]; then
      detalhe=""
      grep -qx 'secretmanager.versions.access' <<< "$PERMS" && detalhe=", inclusive LER valores (secretmanager.versions.access)"
      alerta "$role dá $SM permissões secretmanager.* em TODOS os secrets do projeto${detalhe}."
    fi
    if [ "$KMS" -gt 0 ]; then
      detalhe=""
      grep -qx 'cloudkms.cryptoKeyVersions.useToDecrypt' <<< "$PERMS" && detalhe=", inclusive DECIFRAR (useToDecrypt)"
      alerta "$role dá $KMS permissões cloudkms.* em TODAS as chaves do projeto${detalhe}."
    fi
    if [ "$SM" -eq 0 ] && [ "$KMS" -eq 0 ]; then
      ok "$role não dá acesso a secretmanager.* nem cloudkms.*"
    fi
  done <<< "$ROLES"
fi

# ---------------------------------------------------------------------------------------
titulo "Secret $SECRET_NAME"
if ! api_habilitada secretmanager.googleapis.com; then
  aviso "Secret Manager API desabilitada: nada a verificar."
elif ! gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  aviso "o secret ainda não existe."
else
  LOCAIS="$(gc secrets describe "$SECRET_NAME" --project="$PROJECT_ID" \
    --format='value(replication.userManaged.replicas[].location)')"
  echo "  Replicação: ${LOCAIS:-automática (global)}"

  echo "  Política IAM do secret:"
  # Política sem nenhum binding devolve uma linha só com o separador (um tab), e não
  # string vazia: sem o sed, o teste -z abaixo falha e a tela mostra um tab solto.
  POL_SECRET="$(gc secrets get-iam-policy "$SECRET_NAME" --project="$PROJECT_ID" \
    --flatten='bindings[].members' --format='value(bindings.role,bindings.members)' \
    | sed '/^[[:space:]]*$/d')"
  if [ -z "$POL_SECRET" ]; then echo "    (vazia)"; else recuo <<< "$POL_SECRET"; fi
  if grep -qxF "roles/secretmanager.secretAccessor"$'\t'"serviceAccount:$BACKEND_SA" <<< "$POL_SECRET"; then
    ok "SA do backend tem secretAccessor NO SECRET"
  else
    aviso "SA do backend não tem secretAccessor no secret."
  fi

  echo "  Versões (número, estado, criação — nunca o valor):"
  gc secrets versions list "$SECRET_NAME" --project="$PROJECT_ID" \
    --format='table(name.basename():label=VERSAO,state:label=ESTADO,createTime.date("%Y-%m-%d %H:%M"):label=CRIADA_EM)' \
    | recuo
fi

# ---------------------------------------------------------------------------------------
titulo "Chave KMS $KEYRING/$KEY ($REGION)"
if ! api_habilitada cloudkms.googleapis.com; then
  aviso "Cloud KMS API desabilitada: nada a verificar."
elif ! gcloud kms keys describe "$KEY" --keyring="$KEYRING" --location="$REGION" \
       --project="$PROJECT_ID" >/dev/null 2>&1; then
  aviso "a chave ainda não existe."
else
  # Separador "|" (não tab): campos vazios, como rotação ausente, não deslocam os seguintes.
  IFS='|' read -r PROPOSITO PERIODO PROXIMA ESTADO <<< "$(gc kms keys describe "$KEY" --keyring="$KEYRING" \
    --location="$REGION" --project="$PROJECT_ID" \
    --format='value[separator="|"](purpose,rotationPeriod,nextRotationTime,primary.state)')"
  if [[ "${PERIODO:-}" =~ ^[0-9]+s$ ]]; then
    PERIODO="$(( ${PERIODO%s} / 86400 )) dias"
  fi
  echo "  Purpose: ${PROPOSITO:-?} | Rotação: ${PERIODO:-sem rotação} | Próxima: ${PROXIMA:-?} | Versão primária: ${ESTADO:-?}"

  echo "  Política IAM da chave:"
  POL_CHAVE="$(gc kms keys get-iam-policy "$KEY" --keyring="$KEYRING" --location="$REGION" \
    --project="$PROJECT_ID" --flatten='bindings[].members' \
    --format='value(bindings.role,bindings.members)' | sed '/^[[:space:]]*$/d')"
  if [ -z "$POL_CHAVE" ]; then echo "    (vazia)"; else recuo <<< "$POL_CHAVE"; fi
  if grep -qxF "roles/cloudkms.cryptoKeyEncrypterDecrypter"$'\t'"serviceAccount:$BACKEND_SA" <<< "$POL_CHAVE"; then
    ok "SA do backend tem cryptoKeyEncrypterDecrypter NA CHAVE"
  else
    aviso "SA do backend não tem cryptoKeyEncrypterDecrypter na chave."
  fi
fi

# ---------------------------------------------------------------------------------------
titulo "Resumo"
if [ "$ALERTAS" -eq 0 ]; then
  ok "nenhum alerta."
else
  printf '  %s%d alerta(s) acima.%s\n' "$VERMELHO" "$ALERTAS" "$RESET"
fi
