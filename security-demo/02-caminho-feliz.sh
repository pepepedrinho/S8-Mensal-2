#!/usr/bin/env bash
# Seminário Cloud IAM, Secret Manager e Cloud KMS — Triodelícia
# Slide 12, passos 4 (o backend acessa o Secret) e 6 (operação com a Crypto Key):
# caminho feliz, chamando as rotas de demonstração pelo domínio público.
#
# Não altera nenhum recurso nem política. Nunca exibe valor de secret (as rotas só
# devolvem versão, tamanho e fingerprint) nem o conteúdo das tarefas (só a contagem).
# A saída também é acrescentada ao final de security-demo/evidencias/02-caminho-feliz.txt,
# com um cabeçalho de separação (data e hora UTC-3) por execução.
#
# Pré-requisito: backend publicado com a demo ligada (Cloud Build com _SECURITY_DEMO=true).
# Uso (Git Bash): bash security-demo/02-caminho-feliz.sh
#   Outro endereço: BASE_URL=https://outro.dominio bash security-demo/02-caminho-feliz.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

BASE_URL="${BASE_URL:-https://triodelicia.duckdns.org}"
EVIDENCIA="$SCRIPT_DIR/evidencias/02-caminho-feliz.txt"
CHAVE_ESPERADA="projects/$PROJECT_ID/locations/$REGION/keyRings/$KEYRING/cryptoKeys/$KEY"

CORPO="$(mktemp)"
trap 'rm -f "$CORPO"' EXIT

if command -v jq >/dev/null 2>&1; then TEM_JQ=sim; else TEM_JQ=nao; fi

FALHAS=0
HTTP_CODE=""

titulo() { printf '\n== %s ==\n' "$1"; }
ok()     { printf '  [ok] %s\n' "$1"; }
falha()  { printf '  [FALHA] %s\n' "$1"; FALHAS=$((FALHAS + 1)); }

# Faz a requisição: corpo em $CORPO, código HTTP em $HTTP_CODE.
# POST vai com corpo vazio (--data ''), para mandar Content-Length: 0 ao Load Balancer.
requisitar() {
  local metodo="$1" caminho="$2"
  local extra=()
  [ "$metodo" = "POST" ] && extra=(--data '')
  if ! HTTP_CODE="$(curl -sS --max-time 30 -o "$CORPO" -w '%{http_code}' \
         -X "$metodo" "${extra[@]}" "$BASE_URL$caminho")"; then
    echo "  Falha de rede ao chamar $BASE_URL$caminho (DNS, TLS ou Load Balancer)."
    exit 1
  fi
}

# Campo do JSON da resposta (vazio se não houver jq ou o campo não existir).
campo() {
  [ "$TEM_JQ" = sim ] || return 0
  jq -r "$1 // empty" "$CORPO" 2>/dev/null | tr -d '\r'
}

# Mostra o código HTTP e os campos pedidos (com jq) ou a resposta crua, truncada.
mostrar() {
  local filtro="$1"
  echo "  HTTP $HTTP_CODE"
  if [ "$TEM_JQ" = sim ] && jq -e . "$CORPO" >/dev/null 2>&1; then
    jq -r "$filtro | to_entries[] | select(.value != null) | \"  \(.key): \(.value)\"" "$CORPO" \
      | tr -d '\r'
  else
    printf '  resposta: %s\n' "$(head -c 300 "$CORPO")"
  fi
}

esperar_http() {
  if [ "$HTTP_CODE" = "$1" ]; then ok "HTTP $1"; else falha "esperado HTTP $1, recebido $HTTP_CODE"; fi
}

main() {
  # Cabeçalho de separação: o arquivo de evidência acumula uma seção por execução.
  echo
  echo "======================================================================"
  echo "Execução: $(date -u -d '-3 hours' '+%Y-%m-%d %H:%M:%S') (UTC-3)"
  echo "Demo — caminho feliz (slide 12, passos 4 e 6)"
  echo "======================================================================"
  echo "Alvo: $BASE_URL"
  echo "Projeto: $PROJECT_ID | SA do backend: $BACKEND_SA"
  [ "$TEM_JQ" = sim ] || echo "(jq não encontrado: respostas exibidas cruas)"

  # -------------------------------------------------------------------------------------
  titulo "1/4 — GET /api/security/status"
  requisitar GET /api/security/status
  if [ "$HTTP_CODE" = "404" ]; then
    echo "  HTTP 404: a demo está DESLIGADA neste deploy (/api/security não existe)."
    echo "  Faça o deploy do backend com a substituição _SECURITY_DEMO=true no Cloud Build"
    echo "  e rode este script de novo. (Se a demo estiver ligada, confira se o Load"
    echo "  Balancer encaminha /api/* para o $BACKEND_SERVICE.)"
    exit 1
  fi
  mostrar '{ok, enabled, secret, kmsKey, error_code, hint}'
  esperar_http 200
  if [ "$TEM_JQ" = sim ]; then
    if [ "$(campo .secret)" = "$SECRET_NAME" ]; then
      ok "secret configurado no backend = $SECRET_NAME (config.sh)"
    else
      falha "secret no backend ($(campo .secret)) difere do config.sh ($SECRET_NAME)"
    fi
    if [ "$(campo .kmsKey)" = "$CHAVE_ESPERADA" ]; then
      ok "chave configurada no backend = $KEYRING/$KEY (config.sh)"
    else
      falha "chave no backend difere do config.sh ($CHAVE_ESPERADA)"
    fi
  fi

  # -------------------------------------------------------------------------------------
  titulo "2/4 — Passo 4: GET /api/security/secret?version=latest (backend lê o Secret)"
  requisitar GET "/api/security/secret?version=latest"
  mostrar '{ok, secret, version, length, fingerprint, error_code, hint}'
  esperar_http 200

  # -------------------------------------------------------------------------------------
  titulo "3/4 — Passo 6: POST /api/security/kms/roundtrip (cifrar e decifrar)"
  requisitar POST /api/security/kms/roundtrip
  mostrar '{ok, keyVersion, ciphertextLength, roundtripMatch, error_code, hint}'
  esperar_http 200
  if [ "$TEM_JQ" = sim ]; then
    if [ "$(campo .roundtripMatch)" = "true" ]; then
      ok "roundtripMatch = true (decifrado igual ao original)"
    else
      falha "roundtripMatch diferente de true"
    fi
  fi

  # -------------------------------------------------------------------------------------
  titulo "4/4 — CRUD continua funcionando: GET /api/todos"
  requisitar GET /api/todos
  echo "  HTTP $HTTP_CODE"
  # Só a contagem: o corpo traz o texto das tarefas, que não vai para a evidência.
  if [ "$TEM_JQ" = sim ] && [ "$(jq -r 'type' "$CORPO" 2>/dev/null | tr -d '\r')" = "array" ]; then
    echo "  tarefas: $(jq -r 'length' "$CORPO" | tr -d '\r')"
  fi
  esperar_http 200

  # -------------------------------------------------------------------------------------
  titulo "Resultado"
  if [ "$FALHAS" -eq 0 ]; then
    echo "  Caminho feliz OK."
  else
    echo "  $FALHAS verificação(ões) falharam."
    return 1
  fi
}

mkdir -p "$(dirname "$EVIDENCIA")"
# pipefail: o código de saída é o do main, mesmo passando pelo tee.
main 2>&1 | tee -a "$EVIDENCIA"
