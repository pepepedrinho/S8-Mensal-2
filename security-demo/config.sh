#!/usr/bin/env bash
# Seminário Cloud IAM, Secret Manager e Cloud KMS — Triodelícia
# Sem slide próprio: configuração usada pelo 00-check.sh e pelo 01-setup.sh.
# Configuração compartilhada. Não executar direto: os outros scripts fazem `source`.
#
# BACKEND_SA é descoberta no Cloud Run; para forçar outra conta:
#   BACKEND_SA=nome@projeto.iam.gserviceaccount.com bash security-demo/00-check.sh
#
# No Git Bash a saída do gcloud (Windows) vem com CRLF: toda captura passa por tr -d '\r'.

set -euo pipefail

PROJECT_ID="triodelicia-mensal2-2026"
REGION="southamerica-east1"
BACKEND_SERVICE="triodelicia-backend"
SECRET_NAME="APP_API_KEY"
KEYRING="seminario-seguranca"
KEY="seminario-chave"

COMPUTE_DEFAULT_SA_SUFFIX="-compute@developer.gserviceaccount.com"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' | tr -d '\r')" || {
  echo "Erro: não foi possível ler o projeto $PROJECT_ID (rode gcloud auth login e confira o acesso)." >&2
  exit 1
}

if [ -z "${BACKEND_SA:-}" ]; then
  BACKEND_SA="$(gcloud run services describe "$BACKEND_SERVICE" \
    --project="$PROJECT_ID" --region="$REGION" \
    --format='value(spec.template.spec.serviceAccountName)' | tr -d '\r')" || {
    echo "Erro: não foi possível ler o serviço $BACKEND_SERVICE em $REGION." >&2
    exit 1
  }
  # Sem --service-account no deploy, o Cloud Run usa a conta padrão do Compute.
  if [ -z "$BACKEND_SA" ]; then
    BACKEND_SA="${PROJECT_NUMBER}${COMPUTE_DEFAULT_SA_SUFFIX}"
  fi
fi
