#!/usr/bin/env bash
# Seminário Cloud IAM, Secret Manager e Cloud KMS — Triodelícia
# Slides 4 a 10 e slide 12, passos 7 e 8: menu para forçar erros REAIS (nada simulado no
# código). Cada cenário mostra a descrição e o slide, exibe o comando exato e pede
# confirmação (s/N), chama o endpoint, espera ativamente pelo resultado esperado e oferece
# a restauração.
#
#   S1 IAM no secret ............ slides 8 e 12 (passos 7 e 8)
#   S2 Versão desabilitada ...... slide 7
#   S3 Versão inexistente ....... slide 7
#   S4 Rotação (positivo) ....... slide 7
#   S5 IAM na chave ............. slide 10
#   S6 Versão da chave desab. ... slide 9
#   S7 Ciphertext adulterado .... slide 10
#   S8 Herança do projeto ....... slides 4 e 6
#   S9 Identidade errada ........ slides 4 e 5
#
# Uso (Git Bash):
#   bash security-demo/simulate-errors.sh           menu interativo
#   bash security-demo/simulate-errors.sh status    estado de cada cenário
#   bash security-demo/simulate-errors.sh restore   restaura tudo e roda o 02-caminho-feliz.sh
#
# Nunca exibe nem registra valor de secret. Log: security-demo/evidencias/cenarios.log
# Variáveis opcionais: BASE_URL, S8_PAUSA_S (padrão 120), S8_MONITOR_S (padrão 420).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

BASE_URL="${BASE_URL:-https://triodelicia.duckdns.org}"
LOG="$SCRIPT_DIR/evidencias/cenarios.log"
INTERVALO_S=10
ESPERA_MAX_S=420
S8_PAUSA_S="${S8_PAUSA_S:-120}"
S8_MONITOR_S="${S8_MONITOR_S:-420}"

ROLE_SECRET="roles/secretmanager.secretAccessor"
ROLE_CHAVE="roles/cloudkms.cryptoKeyEncrypterDecrypter"
ROLE_TOKEN="roles/iam.serviceAccountTokenCreator"
MEMBRO="serviceAccount:$BACKEND_SA"
SA_SEM_ACESSO_ID="seminario-sem-acesso"
SA_SEM_ACESSO="${SA_SEM_ACESSO_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
KMS_FLAGS=(--keyring="$KEYRING" --location="$REGION" --project="$PROJECT_ID")

if [ -t 1 ]; then
  VERMELHO=$'\033[1;31m'; AMARELO=$'\033[33m'; VERDE=$'\033[32m'; NEGRITO=$'\033[1m'; RESET=$'\033[0m'
else
  VERMELHO=""; AMARELO=""; VERDE=""; NEGRITO=""; RESET=""
fi
if command -v jq >/dev/null 2>&1; then TEM_JQ=sim; else TEM_JQ=nao; fi

CORPO="$(mktemp)"
ERRO_GCLOUD="$(mktemp)"
trap 'rm -f "$CORPO" "$ERRO_GCLOUD"' EXIT
# Erro ou Ctrl+C: lista os cenários ativos e PERGUNTA antes de restaurar (ao_interromper).
trap 'ao_interromper "Erro inesperado." 1' ERR
trap 'ao_interromper "Interrompido (Ctrl+C)." 130' INT

# --- Saída ------------------------------------------------------------------------------
titulo()    { printf '\n%s== %s ==%s\n' "$NEGRITO" "$1" "$RESET"; }
ok()        { printf '  %s[ok]%s %s\n' "$VERDE" "$RESET" "$1"; }
aviso()     { printf '  %s[!]%s %s\n' "$AMARELO" "$RESET" "$1"; }
alerta()    { printf '  %s[ALERTA] %s%s\n' "$VERMELHO" "$1" "$RESET"; }
descrever() { printf '  %s\n' "$@"; }
hora()          { date -u -d '-3 hours' '+%H:%M:%S'; }
hora_completa() { date -u -d '-3 hours' '+%Y-%m-%d %H:%M:%S'; }

# gcloud sem o \r do Windows.
gc() { gcloud "$@" | tr -d '\r'; }

# --- Confirmação ------------------------------------------------------------------------
# Mostra o comando exato e pergunta; 0 = sim, 1 = não.
confirmar() {
  printf '\n  Comando:\n    %s\n' "$1"
  local resposta=""
  read -r -p "  Executar? [s/N] " resposta || true
  case "$resposta" in s|S|sim|Sim|SIM) return 0 ;; esac
  return 1
}

# Comando sem pipe: o texto exibido sai dos mesmos argumentos executados.
# Retorna 200 se o usuário recusar; senão, o código do próprio comando.
rodar() {
  confirmar "$(printf '%q ' "$@")" || return 200
  "$@"
}

# rodar + mensagens. 0 = executado; 1 = recusado ou falhou.
executar() {
  local rc=0
  rodar "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if [ "$rc" -eq 200 ]; then aviso "Cancelado: comando não executado."; else alerta "O comando falhou (código $rc)."; fi
  return 1
}

# --- HTTP ---------------------------------------------------------------------------------
HTTP_CODE=""
ERROR_CODE=""

# Campo de primeiro nível do JSON da última resposta (com ou sem jq). Nunca falha.
campo() {
  local nome="$1" v=""
  if [ "$TEM_JQ" = sim ]; then
    v="$(jq -r --arg c "$nome" '.[$c]? | select(. != null)' "$CORPO" 2>/dev/null | tr -d '\r' || true)"
  else
    v="$(sed -n "s/.*\"$nome\":\"\([^\"]*\)\".*/\1/p" "$CORPO" 2>/dev/null | head -n1 || true)"
    if [ -z "$v" ]; then
      v="$(sed -n "s/.*\"$nome\":\([^,}\"]*\).*/\1/p" "$CORPO" 2>/dev/null | head -n1 || true)"
    fi
  fi
  printf '%s' "$v"
}

# Corpo em $CORPO, código em $HTTP_CODE ("000" = falha de rede), error_code em $ERROR_CODE.
# POST vai com corpo vazio (--data ''): Content-Length: 0 para o Load Balancer.
requisitar() {
  local metodo="$1" caminho="$2"
  local extra=()
  if [ "$metodo" = "POST" ]; then extra=(--data ''); fi
  : > "$CORPO"
  HTTP_CODE="$(curl -sS --max-time 30 -o "$CORPO" -w '%{http_code}' \
    -X "$metodo" "${extra[@]}" "$BASE_URL$caminho" 2>/dev/null || true)"
  if [ -z "$HTTP_CODE" ]; then HTTP_CODE="000"; fi
  ERROR_CODE="$(campo error_code)"
}

# Uma linha com o código HTTP e os campos relevantes presentes na resposta.
resumo_resposta() {
  local s="HTTP $HTTP_CODE" c v
  for c in error_code version fingerprint keyVersion roundtripMatch; do
    v="$(campo "$c")"
    if [ -n "$v" ]; then s+=" | $c=$v"; fi
  done
  printf '%s' "$s"
}

mostrar_resposta() {
  local dica
  printf '  %s\n' "$(resumo_resposta)"
  dica="$(campo hint)"
  if [ -n "$dica" ]; then printf '  dica: %s\n' "$dica"; fi
}

# --- Resultado de cada cenário (para o log) ------------------------------------------------
R_INICIO="-"; R_HORA="-"; R_ESPERA="-"; R_HTTP="-"; R_CODE="-"
ESPERA_HORA="-"; ESPERA_SEGUNDOS="-"; ESPERA_HTTP="-"; ESPERA_CODE="-"

novo_cenario() {
  R_INICIO="$(hora_completa)"; R_HORA="-"; R_ESPERA="-"; R_HTTP="-"; R_CODE="-"
}

guardar_resultado() {
  R_HORA="$ESPERA_HORA"; R_ESPERA="$ESPERA_SEGUNDOS"; R_HTTP="$ESPERA_HTTP"; R_CODE="$ESPERA_CODE"
}

# Uma linha por cenário. Nunca contém valor de secret.
registrar() {
  local cenario="$1" restaurado="$2"
  mkdir -p "$(dirname "$LOG")"
  printf 'cenario=%s | inicio=%s | resultado=%s | espera_s=%s | http=%s | error_code=%s | restaurado=%s\n' \
    "$cenario" "$R_INICIO" "$R_HORA" "$R_ESPERA" "$R_HTTP" "$R_CODE" "$restaurado" >> "$LOG"
  echo "  Registrado em security-demo/evidencias/cenarios.log"
}

# --- Espera ativa -------------------------------------------------------------------------
resultado_bate() {
  local http_esp="$1" code_esp="$2" extra="${3:-}"
  [ "$HTTP_CODE" = "$http_esp" ] || return 1
  if [ "$code_esp" = "-" ]; then
    [ -z "$ERROR_CODE" ] || return 1
  else
    [ "$ERROR_CODE" = "$code_esp" ] || return 1
  fi
  if [ -n "$extra" ]; then "$extra" || return 1; fi
  return 0
}

# Consulta o endpoint a cada INTERVALO_S até o resultado esperado ou ESPERA_MAX_S.
# $1 método, $2 caminho, $3 HTTP esperado, $4 error_code esperado ("-" = sem erro),
# $5 opcional: função que também precisa retornar 0. Preenche ESPERA_*.
esperar() {
  local metodo="$1" caminho="$2" http_esp="$3" code_esp="$4" extra="${5:-}"
  local inicio decorrido tentativa=0 total esperado
  total=$((ESPERA_MAX_S / INTERVALO_S + 1))
  inicio="$(date +%s)"
  esperado="HTTP $http_esp"
  if [ "$code_esp" != "-" ]; then esperado+=" $code_esp"; fi
  echo "  Aguardando $esperado em $metodo $caminho (a cada ${INTERVALO_S}s, até $((ESPERA_MAX_S / 60)) min)"
  while :; do
    tentativa=$((tentativa + 1))
    requisitar "$metodo" "$caminho"
    decorrido=$(( $(date +%s) - inicio ))
    printf '\r  [%02d/%02d] %s  +%3ss  %s      ' "$tentativa" "$total" "$(hora)" "$decorrido" "$(resumo_resposta)"
    if resultado_bate "$http_esp" "$code_esp" "$extra"; then
      printf '\n'
      ESPERA_HORA="$(hora_completa)"; ESPERA_SEGUNDOS="$decorrido"
      ESPERA_HTTP="$HTTP_CODE"; ESPERA_CODE="${ERROR_CODE:--}"
      ok "resultado esperado às $(hora) (UTC-3), após ${decorrido}s"
      mostrar_resposta
      return 0
    fi
    if [ "$tentativa" -ge "$total" ]; then
      printf '\n'
      ESPERA_HORA="timeout"; ESPERA_SEGUNDOS="$decorrido"
      ESPERA_HTTP="$HTTP_CODE"; ESPERA_CODE="${ERROR_CODE:--}"
      alerta "$esperado não apareceu em $((ESPERA_MAX_S / 60)) min. Última resposta:"
      mostrar_resposta
      return 1
    fi
    sleep "$INTERVALO_S"
  done
}

# Exige que o endpoint SIGA em 200 por $2 segundos (S8). Preenche ESPERA_*.
monitorar_200() {
  local caminho="$1" duracao="$2" inicio decorrido tentativa=0 total
  total=$((duracao / INTERVALO_S + 1))
  inicio="$(date +%s)"
  echo "  Monitorando GET $caminho: precisa continuar em 200 por $((duracao / 60)) min"
  while :; do
    tentativa=$((tentativa + 1))
    requisitar GET "$caminho"
    decorrido=$(( $(date +%s) - inicio ))
    printf '\r  [%02d/%02d] %s  +%3ss  %s      ' "$tentativa" "$total" "$(hora)" "$decorrido" "$(resumo_resposta)"
    ESPERA_HORA="$(hora_completa)"; ESPERA_SEGUNDOS="$decorrido"
    ESPERA_HTTP="$HTTP_CODE"; ESPERA_CODE="${ERROR_CODE:--}"
    if [ "$HTTP_CODE" != "200" ]; then
      printf '\n'
      alerta "a resposta deixou de ser 200 às $(hora) (após ${decorrido}s):"
      mostrar_resposta
      return 1
    fi
    if [ "$tentativa" -ge "$total" ]; then
      printf '\n'
      ok "continuou 200 durante ${decorrido}s (até $(hora) UTC-3)"
      return 0
    fi
    sleep "$INTERVALO_S"
  done
}

pausa() {
  local restante="$1" passo
  while [ "$restante" -gt 0 ]; do
    printf '\r  aguardando %3ss...   ' "$restante"
    passo=$(( restante < INTERVALO_S ? restante : INTERVALO_S ))
    sleep "$passo"
    restante=$((restante - passo))
  done
  printf '\r  pausa concluída.          \n'
}

# --- Pré-condições --------------------------------------------------------------------------
verificar_recursos() {
  if ! gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1 \
     || ! gcloud kms keys describe "$KEY" "${KMS_FLAGS[@]}" >/dev/null 2>&1; then
    alerta "secret $SECRET_NAME ou chave $KEYRING/$KEY não encontrados (ou sem permissão de leitura)."
    descrever "Rode antes: bash security-demo/01-setup.sh"
    exit 1
  fi
}

# Antes de qualquer cenário: a demo precisa estar ligada no backend.
verificar_demo() {
  requisitar GET /api/security/status
  if [ "$HTTP_CODE" = "200" ]; then
    ok "demo ligada em $BASE_URL"
    return 0
  fi
  if [ "$HTTP_CODE" = "404" ]; then
    alerta "GET /api/security/status respondeu 404: a demo está DESLIGADA neste deploy."
  else
    alerta "GET /api/security/status respondeu HTTP $HTTP_CODE."
  fi
  descrever "Faça o deploy do backend com a substituição _SECURITY_DEMO=true no Cloud Build" \
            "e rode este script de novo. Nenhum cenário foi executado."
  exit 1
}

# --- Estado no GCP ----------------------------------------------------------------------------
politica_tem() { grep -qxF "$2"$'\t'"$3" <<< "$1"; }

pol_secret() {
  gc secrets get-iam-policy "$SECRET_NAME" --project="$PROJECT_ID" \
    --flatten='bindings[].members' --format='value(bindings.role,bindings.members)'
}
pol_chave() {
  gc kms keys get-iam-policy "$KEY" "${KMS_FLAGS[@]}" \
    --flatten='bindings[].members' --format='value(bindings.role,bindings.members)'
}
pol_projeto() {
  gc projects get-iam-policy "$PROJECT_ID" \
    --flatten='bindings[].members' --format='value(bindings.role,bindings.members)'
}

tem_binding_secret()  { politica_tem "$(pol_secret)" "$ROLE_SECRET" "$MEMBRO"; }
tem_binding_chave()   { politica_tem "$(pol_chave)" "$ROLE_CHAVE" "$MEMBRO"; }
tem_binding_projeto() { politica_tem "$(pol_projeto)" "$ROLE_SECRET" "$MEMBRO"; }

roles_kms_no_projeto() {
  pol_projeto | awk -F'\t' -v m="$MEMBRO" '$2 == m && $1 ~ /^roles\/cloudkms\./ { print $1 }'
}

# "nome<TAB>estado" da versão mais recente do secret (é a que o alias latest usa).
ultima_versao_secret() {
  gc secrets versions list "$SECRET_NAME" --project="$PROJECT_ID" \
    --sort-by='~createTime' --limit=1 --format='value(name,state)'
}

# "nome<TAB>estado" da versão primária da chave.
versao_primaria_chave() {
  gc kms keys describe "$KEY" "${KMS_FLAGS[@]}" --format='value(primary.name,primary.state)'
}

contagem_versoes() {
  gc secrets versions list "$SECRET_NAME" --project="$PROJECT_ID" --format='value(state)' \
    | sort | uniq -c | awk '{ printf "%s%s=%s", sep, $2, $1; sep = ", " } END { print "" }'
}

revisao_backend() {
  gc run services describe "$BACKEND_SERVICE" --project="$PROJECT_ID" --region="$REGION" \
    --format='value(status.latestReadyRevisionName)'
}

membro_minha_conta() {
  local conta
  conta="$(gc config get-value account 2>/dev/null || true)"
  if [ -z "$conta" ]; then return 1; fi
  if [[ "$conta" == *.gserviceaccount.com ]]; then
    printf 'serviceAccount:%s' "$conta"
  else
    printf 'user:%s' "$conta"
  fi
}

sa_sem_acesso_existe() {
  gcloud iam service-accounts describe "$SA_SEM_ACESSO" --project="$PROJECT_ID" >/dev/null 2>&1
}

tem_token_creator() {
  local membro
  membro="$(membro_minha_conta)" || return 1
  sa_sem_acesso_existe || return 1
  politica_tem "$(gc iam service-accounts get-iam-policy "$SA_SEM_ACESSO" --project="$PROJECT_ID" \
    --flatten='bindings[].members' --format='value(bindings.role,bindings.members)')" "$ROLE_TOKEN" "$membro"
}

# --- Restaurações reutilizadas por cenários e pelo restore ---------------------------------
restaurar_binding_secret() {
  if tem_binding_secret; then ok "a SA já tem $ROLE_SECRET no secret"; return 0; fi
  executar gcloud secrets add-iam-policy-binding "$SECRET_NAME" --project="$PROJECT_ID" \
    --member="$MEMBRO" --role="$ROLE_SECRET" --format=none
}

restaurar_binding_chave() {
  if tem_binding_chave; then ok "a SA já tem $ROLE_CHAVE na chave"; return 0; fi
  executar gcloud kms keys add-iam-policy-binding "$KEY" "${KMS_FLAGS[@]}" \
    --member="$MEMBRO" --role="$ROLE_CHAVE" --format=none
}

remover_binding_projeto() {
  if ! tem_binding_projeto; then ok "não há $ROLE_SECRET da SA no projeto"; return 0; fi
  alerta "O próximo comando altera a política IAM do PROJETO."
  executar gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="$MEMBRO" --role="$ROLE_SECRET" --condition=None --format=none
}

remover_token_creator() {
  local membro
  if ! tem_token_creator; then ok "sua conta não tem $ROLE_TOKEN na $SA_SEM_ACESSO_ID"; return 0; fi
  membro="$(membro_minha_conta)"
  executar gcloud iam service-accounts remove-iam-policy-binding "$SA_SEM_ACESSO" --project="$PROJECT_ID" \
    --member="$membro" --role="$ROLE_TOKEN" --format=none
}

# Restauração de cenário que deve terminar com o endpoint em 200.
# $1 cenário, $2 função de restauração, $3 método, $4 caminho.
restaurar_e_confirmar() {
  local cenario="$1" funcao="$2" metodo="$3" caminho="$4" restaurado="pendente"
  titulo "$cenario — restaurar"
  if "$funcao"; then
    if esperar "$metodo" "$caminho" 200 -; then
      restaurado="$ESPERA_HORA"
    else
      restaurado="$(hora_completa) (200 não confirmado)"
    fi
  else
    alerta "Restauração pendente: rode bash security-demo/simulate-errors.sh restore"
  fi
  registrar "$cenario" "$restaurado"
}

# --- Cenários -------------------------------------------------------------------------------
cenario_s1() {
  titulo "S1 — IAM no secret (slides 8 e 12, passos 7 e 8)"
  descrever "Remove $ROLE_SECRET da SA do backend NO SECRET." \
            "Esperado: GET /api/security/secret -> 403 PERMISSION_DENIED (após a propagação do IAM)."
  verificar_demo
  if tem_binding_projeto; then
    alerta "S8 está ativo: a SA tem $ROLE_SECRET no PROJETO e o 403 não vai aparecer. Rode restore antes."
    return 0
  fi
  novo_cenario
  if tem_binding_secret; then
    executar gcloud secrets remove-iam-policy-binding "$SECRET_NAME" --project="$PROJECT_ID" \
      --member="$MEMBRO" --role="$ROLE_SECRET" --format=none || return 0
  else
    aviso "o binding já não existe no secret (cenário já ativo?): só aguardando o resultado."
  fi
  esperar GET /api/security/secret 403 PERMISSION_DENIED || true
  guardar_resultado
  restaurar_e_confirmar S1 restaurar_binding_secret GET /api/security/secret
}

cenario_s2() {
  local nome estado versao
  titulo "S2 — Versão desabilitada (slide 7)"
  descrever "Desabilita a versão mais recente do secret (a que o alias latest usa)." \
            "Esperado: GET /api/security/secret?version=latest -> 409 FAILED_PRECONDITION."
  verificar_demo
  IFS=$'\t' read -r nome estado <<< "$(ultima_versao_secret)"
  versao="${nome##*/}"
  echo "  Versão mais recente: $versao ($estado)"
  novo_cenario
  case "$estado" in
    ENABLED)
      executar gcloud secrets versions disable "$versao" --secret="$SECRET_NAME" --project="$PROJECT_ID" || return 0 ;;
    DISABLED)
      aviso "a versão $versao já está desabilitada: só aguardando o resultado." ;;
    *)
      alerta "a versão $versao está $estado e não pode ser reabilitada. Use o S4 para criar outra."
      return 0 ;;
  esac
  esperar GET "/api/security/secret?version=latest" 409 FAILED_PRECONDITION || true
  guardar_resultado

  titulo "S2 — restaurar"
  local restaurado="pendente"
  if executar gcloud secrets versions enable "$versao" --secret="$SECRET_NAME" --project="$PROJECT_ID"; then
    if esperar GET "/api/security/secret?version=latest" 200 -; then
      restaurado="$ESPERA_HORA"
    else
      restaurado="$(hora_completa) (200 não confirmado)"
    fi
  else
    alerta "Restauração pendente: rode bash security-demo/simulate-errors.sh restore"
  fi
  registrar S2 "$restaurado"
}

cenario_s3() {
  local h1 c1 h2 c2
  titulo "S3 — Versão inexistente (slide 7)"
  descrever "Nenhuma mudança no GCP." \
            "Esperado: ?version=999 -> 404 NOT_FOUND (resposta da API)" \
            "          ?version=abc -> 400 INVALID_VERSION (validação da própria aplicação)."
  verificar_demo
  if ! confirmar "curl -X GET '$BASE_URL/api/security/secret?version=999'  e  '...?version=abc'"; then
    aviso "Cancelado."; return 0
  fi
  novo_cenario
  requisitar GET "/api/security/secret?version=999"
  h1="$HTTP_CODE"; c1="${ERROR_CODE:--}"
  echo "  ?version=999"; mostrar_resposta
  if [ "$h1" = "404" ] && [ "$c1" = "NOT_FOUND" ]; then ok "404 NOT_FOUND"; else alerta "esperado 404 NOT_FOUND"; fi
  requisitar GET "/api/security/secret?version=abc"
  h2="$HTTP_CODE"; c2="${ERROR_CODE:--}"
  echo "  ?version=abc"; mostrar_resposta
  if [ "$h2" = "400" ] && [ "$c2" = "INVALID_VERSION" ]; then ok "400 INVALID_VERSION"; else alerta "esperado 400 INVALID_VERSION"; fi
  R_HORA="$(hora_completa)"; R_ESPERA=0; R_HTTP="$h1,$h2"; R_CODE="$c1,$c2"
  registrar S3 "n/a (nada alterado)"
}

S4_VERSAO_ANTES=""
versao_mudou() {
  local v
  v="$(campo version)"
  [ -n "$v" ] && [ "$v" != "$S4_VERSAO_ANTES" ]
}

cenario_s4() {
  local fp_antes rev_antes rev_depois fp_depois v_depois
  titulo "S4 — Rotação, cenário positivo (slide 7: v1 -> v2 -> v3)"
  descrever "Adiciona uma nova versão com valor aleatório (nunca exibido)." \
            "Esperado: 200 com version e fingerprint novos, SEM redeploy do backend."
  verificar_demo
  requisitar GET "/api/security/secret?version=latest"
  if [ "$HTTP_CODE" != "200" ]; then
    alerta "o estado atual não é 200; restaure os outros cenários antes:"
    mostrar_resposta
    return 0
  fi
  S4_VERSAO_ANTES="$(campo version)"; fp_antes="$(campo fingerprint)"
  rev_antes="$(revisao_backend)"
  echo "  Antes: versão $S4_VERSAO_ANTES | fingerprint $fp_antes | revisão $rev_antes"
  echo "  Versões do secret: $(contagem_versoes)"

  novo_cenario
  if ! confirmar "openssl rand -base64 32 | tr -d '\\n' | gcloud secrets versions add $SECRET_NAME --project=$PROJECT_ID --data-file=-"; then
    aviso "Cancelado."; return 0
  fi
  if ! openssl rand -base64 32 | tr -d '\n' \
       | gcloud secrets versions add "$SECRET_NAME" --project="$PROJECT_ID" --data-file=-; then
    alerta "falha ao adicionar a versão."; return 0
  fi

  esperar GET "/api/security/secret?version=latest" 200 - versao_mudou || true
  guardar_resultado
  v_depois="$(campo version)"; fp_depois="$(campo fingerprint)"
  rev_depois="$(revisao_backend)"
  echo "  Depois: versão $v_depois | fingerprint $fp_depois | revisão $rev_depois"
  if [ "$fp_depois" != "$fp_antes" ]; then ok "fingerprint mudou: o backend já lê o valor novo"; else alerta "fingerprint igual"; fi
  if [ "$rev_depois" = "$rev_antes" ]; then ok "mesma revisão do Cloud Run: nenhum redeploy"; else aviso "a revisão mudou durante o teste"; fi
  echo "  Versões do secret agora: $(contagem_versoes)"
  registrar S4 "n/a (rotação é o comportamento normal)"
}

cenario_s5() {
  local kms_proj
  titulo "S5 — IAM na chave (slide 10)"
  descrever "Remove $ROLE_CHAVE da SA do backend NA CHAVE." \
            "Esperado: POST /api/security/kms/roundtrip -> 403 PERMISSION_DENIED."
  verificar_demo
  kms_proj="$(roles_kms_no_projeto)"
  if [ -n "$kms_proj" ]; then
    alerta "a SA tem role de KMS no PROJETO ($kms_proj): o 403 não vai aparecer."
    return 0
  fi
  novo_cenario
  if tem_binding_chave; then
    executar gcloud kms keys remove-iam-policy-binding "$KEY" "${KMS_FLAGS[@]}" \
      --member="$MEMBRO" --role="$ROLE_CHAVE" --format=none || return 0
  else
    aviso "o binding já não existe na chave (cenário já ativo?): só aguardando o resultado."
  fi
  esperar POST /api/security/kms/roundtrip 403 PERMISSION_DENIED || true
  guardar_resultado
  restaurar_e_confirmar S5 restaurar_binding_chave POST /api/security/kms/roundtrip
}

cenario_s6() {
  local nome estado versao
  titulo "S6 — Versão da chave desabilitada (slide 9)"
  descrever "Desabilita a versão primária da chave." \
            "Esperado: POST /api/security/kms/roundtrip -> 409 FAILED_PRECONDITION." \
            "Mudanças de estado no KMS são eventualmente consistentes: podem passar da janela."
  verificar_demo
  IFS=$'\t' read -r nome estado <<< "$(versao_primaria_chave)"
  versao="${nome##*/}"
  echo "  Versão primária: $versao ($estado)"
  novo_cenario
  case "$estado" in
    ENABLED)
      executar gcloud kms keys versions disable "$versao" --key="$KEY" "${KMS_FLAGS[@]}" || return 0 ;;
    DISABLED)
      aviso "a versão $versao já está desabilitada: só aguardando o resultado." ;;
    *)
      alerta "a versão primária está $estado: este cenário não se aplica."
      return 0 ;;
  esac
  esperar POST /api/security/kms/roundtrip 409 FAILED_PRECONDITION || true
  guardar_resultado

  titulo "S6 — restaurar"
  local restaurado="pendente"
  if executar gcloud kms keys versions enable "$versao" --key="$KEY" "${KMS_FLAGS[@]}"; then
    if esperar POST /api/security/kms/roundtrip 200 -; then
      restaurado="$ESPERA_HORA"
    else
      restaurado="$(hora_completa) (200 não confirmado)"
    fi
  else
    alerta "Restauração pendente: rode bash security-demo/simulate-errors.sh restore"
  fi
  registrar S6 "$restaurado"
}

cenario_s7() {
  titulo "S7 — Dado cifrado adulterado (slide 10)"
  descrever "Nenhuma mudança no GCP: o backend cifra, altera 1 byte e tenta decifrar." \
            "Esperado: 422 INVALID_ARGUMENT (o KMS detecta a adulteração)."
  verificar_demo
  if ! confirmar "curl -X POST --data '' '$BASE_URL/api/security/kms/tamper'"; then
    aviso "Cancelado."; return 0
  fi
  novo_cenario
  requisitar POST /api/security/kms/tamper
  mostrar_resposta
  if [ "$ERROR_CODE" = "TAMPER_NOT_DETECTED" ]; then
    alerta "RESULTADO INESPERADO: o KMS aceitou o ciphertext adulterado (TAMPER_NOT_DETECTED)."
  elif [ "$HTTP_CODE" = "422" ] && [ "$ERROR_CODE" = "INVALID_ARGUMENT" ]; then
    ok "422 INVALID_ARGUMENT: adulteração detectada"
  else
    aviso "resultado diferente do esperado (outro cenário ativo?)"
  fi
  R_HORA="$(hora_completa)"; R_ESPERA=0; R_HTTP="$HTTP_CODE"; R_CODE="${ERROR_CODE:--}"
  registrar S7 "n/a (nada alterado)"
}

cenario_s8() {
  titulo "S8 — Falha de configuração por herança (slides 4 e 6, menor privilégio)"
  descrever "a) concede $ROLE_SECRET à SA NO PROJETO;" \
            "b) remove o binding da SA NO SECRET." \
            "Esperado: GET /api/security/secret CONTINUA 200, porque a permissão do projeto é herdada."
  printf '\n  %sATENÇÃO: este cenário altera a política IAM do PROJETO %s.%s\n' "$VERMELHO" "$PROJECT_ID" "$RESET"
  verificar_demo
  if ! tem_binding_secret; then
    alerta "a SA não tem o binding no secret: restaure o S1 antes (restore)."
    return 0
  fi
  novo_cenario

  titulo "S8 — etapa a: conceder no PROJETO"
  if tem_binding_projeto; then
    aviso "a SA já tem $ROLE_SECRET no projeto."
  else
    alerta "O próximo comando altera a política IAM do PROJETO."
    executar gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="$MEMBRO" --role="$ROLE_SECRET" --condition=None --format=none || return 0
  fi
  echo "  Pausa de ${S8_PAUSA_S}s para a role do projeto propagar antes da etapa b."
  pausa "$S8_PAUSA_S"

  titulo "S8 — etapa b: remover NO SECRET"
  if ! executar gcloud secrets remove-iam-policy-binding "$SECRET_NAME" --project="$PROJECT_ID" \
         --member="$MEMBRO" --role="$ROLE_SECRET" --format=none; then
    alerta "Etapa b não executada. A role no projeto continua: rode restore para removê-la."
    R_HORA="-"; registrar S8 "pendente"
    return 0
  fi

  # Um 200 logo após a remoção não prova nada (a remoção também propaga):
  # o endpoint precisa continuar 200 durante toda a janela.
  monitorar_200 /api/security/secret "$S8_MONITOR_S" || true
  guardar_resultado
  if [ "$R_HTTP" = "200" ]; then
    descrever "" \
      "Por quê: políticas de permissão do IAM são ADITIVAS e herdadas (projeto -> secret)." \
      "Remover o binding no secret não retira o que foi concedido no projeto; a SA continua" \
      "lendo ESTE e TODOS os outros secrets do projeto. Uma role ampla em nível alto anula" \
      "o controle feito no recurso; por isso o menor privilégio concede no próprio recurso."
  fi

  # Restaura primeiro o binding do secret e só depois remove o do projeto:
  # na ordem inversa haveria uma janela sem acesso.
  titulo "S8 — restaurar"
  local restaurado="pendente"
  if restaurar_binding_secret && remover_binding_projeto; then
    if esperar GET /api/security/secret 200 -; then
      restaurado="$ESPERA_HORA"
    else
      restaurado="$(hora_completa) (200 não confirmado)"
    fi
  else
    alerta "Restauração pendente: rode bash security-demo/simulate-errors.sh restore"
  fi
  registrar S8 "$restaurado"
}

ACESSO_RC=0
ACESSO_CLASSE=""
# Tenta ler o secret como a SA sem acesso. A saída (que seria o valor) vai para /dev/null;
# o stderr só é usado para classificar o erro e nunca é exibido.
tentar_acesso_impersonado() {
  ACESSO_RC=0
  : > "$ERRO_GCLOUD"
  gcloud secrets versions access latest --secret="$SECRET_NAME" --project="$PROJECT_ID" \
    --impersonate-service-account="$SA_SEM_ACESSO" > /dev/null 2> "$ERRO_GCLOUD" || ACESSO_RC=$?
  if [ "$ACESSO_RC" -eq 0 ]; then
    ACESSO_CLASSE="ACESSO_CONCEDIDO"
  elif grep -q "secretmanager.versions.access" "$ERRO_GCLOUD"; then
    ACESSO_CLASSE="PERMISSION_DENIED"
  elif grep -qE "Failed to impersonate|getAccessToken|serviceAccountTokenCreator" "$ERRO_GCLOUD"; then
    ACESSO_CLASSE="IMPERSONACAO_NEGADA"
  else
    ACESSO_CLASSE="OUTRO_ERRO"
  fi
  : > "$ERRO_GCLOUD"
}

cenario_s9() {
  local membro tentativa=0 total inicio decorrido
  titulo "S9 — Identidade errada (slides 4 e 5)"
  descrever "Tenta ler o secret como OUTRA service account ($SA_SEM_ACESSO_ID, sem nenhuma role)," \
            "via --impersonate-service-account. Esperado: PERMISSION_DENIED no gcloud." \
            "A saída vai para /dev/null: só o código de saída é exibido."
  verificar_demo
  membro="$(membro_minha_conta)" || { alerta "nenhuma conta ativa no gcloud (gcloud auth login)."; return 0; }
  novo_cenario

  if ! sa_sem_acesso_existe; then
    aviso "a SA $SA_SEM_ACESSO não existe. Ela será criada SEM nenhuma role (custo zero)."
    executar gcloud iam service-accounts create "$SA_SEM_ACESSO_ID" --project="$PROJECT_ID" \
      --display-name="Seminario - SA sem acesso (S9)" \
      --description="Sem nenhuma role. Usada so para demonstrar PERMISSION_DENIED." || return 0
    echo "  Pausa de 30s: uma SA recém-criada demora a ficar utilizável nas políticas."
    pausa 30
  fi
  # Captura antes do grep: com pipefail, "gc ... | grep -q" pode falhar por SIGPIPE.
  local politicas
  politicas="$(pol_secret)"$'\n'"$(pol_projeto)"
  if grep -qF "serviceAccount:$SA_SEM_ACESSO" <<< "$politicas"; then
    alerta "a $SA_SEM_ACESSO_ID tem bindings no secret ou no projeto: ela deveria estar vazia."
  fi

  if tem_token_creator; then
    ok "sua conta ($membro) já pode impersonar a $SA_SEM_ACESSO_ID"
  else
    descrever "Para impersonar, sua conta precisa de $ROLE_TOKEN NESSA SA (não no projeto):"
    executar gcloud iam service-accounts add-iam-policy-binding "$SA_SEM_ACESSO" --project="$PROJECT_ID" \
      --member="$membro" --role="$ROLE_TOKEN" --format=none || return 0
  fi

  if ! confirmar "gcloud secrets versions access latest --secret=$SECRET_NAME --project=$PROJECT_ID --impersonate-service-account=$SA_SEM_ACESSO > /dev/null"; then
    aviso "Cancelado."
  else
    R_INICIO="$(hora_completa)"
    total=$((ESPERA_MAX_S / INTERVALO_S + 1))
    inicio="$(date +%s)"
    echo "  Tentando a cada ${INTERVALO_S}s enquanto a impersonação ainda não propagou (até $((ESPERA_MAX_S / 60)) min)"
    while :; do
      tentativa=$((tentativa + 1))
      tentar_acesso_impersonado
      decorrido=$(( $(date +%s) - inicio ))
      printf '\r  [%02d/%02d] %s  +%3ss  exit=%s  %s      ' "$tentativa" "$total" "$(hora)" "$decorrido" "$ACESSO_RC" "$ACESSO_CLASSE"
      if [ "$ACESSO_CLASSE" != "IMPERSONACAO_NEGADA" ] || [ "$tentativa" -ge "$total" ]; then break; fi
      sleep "$INTERVALO_S"
    done
    printf '\n'
    R_HORA="$(hora_completa)"; R_ESPERA="$decorrido"; R_HTTP="exit=$ACESSO_RC"; R_CODE="$ACESSO_CLASSE"
    case "$ACESSO_CLASSE" in
      PERMISSION_DENIED)
        ok "PERMISSION_DENIED às $(hora) (após ${decorrido}s): a identidade é outra e não tem role no secret" ;;
      ACESSO_CONCEDIDO)
        alerta "INESPERADO: a $SA_SEM_ACESSO_ID conseguiu ler o secret (valor descartado em /dev/null). Revise as políticas!" ;;
      IMPERSONACAO_NEGADA)
        alerta "a impersonação continuou negada até o fim da janela ($ROLE_TOKEN ainda não propagou)." ;;
      *)
        alerta "erro diferente do esperado (exit=$ACESSO_RC)." ;;
    esac
  fi

  titulo "S9 — restaurar"
  local restaurado="pendente"
  if remover_token_creator; then
    restaurado="$(hora_completa)"
    ok "a SA $SA_SEM_ACESSO_ID foi mantida, vazia (custo zero)"
  else
    alerta "Restauração pendente: rode bash security-demo/simulate-errors.sh restore"
  fi
  registrar S9 "$restaurado"
}

# --- Subcomandos ----------------------------------------------------------------------------
linha_estado() {  # $1 cenário, $2 ativo|restaurado|info, $3 detalhe
  case "$2" in
    ativo)      printf '  %-4s %sATIVO%s       %s\n' "$1" "$VERMELHO" "$RESET" "$3" ;;
    restaurado) printf '  %-4s %srestaurado%s  %s\n' "$1" "$VERDE" "$RESET" "$3" ;;
    *)          printf '  %-4s -           %s\n' "$1" "$3" ;;
  esac
}

mostrar_status() {
  local nome estado
  titulo "Estado dos cenários — $(hora_completa) (UTC-3)"
  requisitar GET /api/security/status
  case "$HTTP_CODE" in
    200) echo "  Demo: ligada em $BASE_URL" ;;
    404) echo "  Demo: DESLIGADA (deploy com _SECURITY_DEMO=true para os cenários)" ;;
    *)   echo "  Demo: /api/security/status respondeu HTTP $HTTP_CODE" ;;
  esac
  echo

  if tem_binding_secret; then linha_estado S1 restaurado "SA tem $ROLE_SECRET no secret"
  else linha_estado S1 ativo "SA SEM $ROLE_SECRET no secret"; fi

  IFS=$'\t' read -r nome estado <<< "$(ultima_versao_secret)"
  if [ "$estado" = "ENABLED" ]; then linha_estado S2 restaurado "versão mais recente ${nome##*/} ENABLED"
  else linha_estado S2 ativo "versão mais recente ${nome##*/} $estado"; fi

  linha_estado S3 info "sem estado (não altera nada)"
  linha_estado S4 info "versões do secret: $(contagem_versoes)"

  if tem_binding_chave; then linha_estado S5 restaurado "SA tem $ROLE_CHAVE na chave"
  else linha_estado S5 ativo "SA SEM $ROLE_CHAVE na chave"; fi

  IFS=$'\t' read -r nome estado <<< "$(versao_primaria_chave)"
  if [ "$estado" = "ENABLED" ]; then linha_estado S6 restaurado "versão primária ${nome##*/} ENABLED"
  else linha_estado S6 ativo "versão primária ${nome##*/} $estado"; fi

  linha_estado S7 info "sem estado (não altera nada)"

  if tem_binding_projeto; then linha_estado S8 ativo "SA tem $ROLE_SECRET no PROJETO (herança)"
  else linha_estado S8 restaurado "nenhum $ROLE_SECRET da SA no projeto"; fi

  if ! sa_sem_acesso_existe; then linha_estado S9 info "$SA_SEM_ACESSO_ID não existe"
  elif tem_token_creator; then linha_estado S9 ativo "sua conta tem $ROLE_TOKEN na $SA_SEM_ACESSO_ID"
  else linha_estado S9 restaurado "$SA_SEM_ACESSO_ID existe, vazia; sem $ROLE_TOKEN"; fi
}

# Só os cenários que alteram o GCP e estão ativos agora. Leitura que falhar conta como
# "não verificado" (e não como ativo). Preenche ATIVOS e INCERTOS.
ATIVOS=0
INCERTOS=0
listar_ativos() {
  local pol nome estado
  ATIVOS=0; INCERTOS=0
  marcar()      { linha_estado "$1" ativo "$2"; ATIVOS=$((ATIVOS + 1)); }
  nao_lido()    { aviso "$1: não verificado (falha ao ler $2)"; INCERTOS=$((INCERTOS + 1)); }

  if pol="$(pol_secret)"; then
    if ! politica_tem "$pol" "$ROLE_SECRET" "$MEMBRO"; then marcar S1 "SA SEM $ROLE_SECRET no secret"; fi
  else nao_lido S1 "a política do secret"; fi

  if pol="$(ultima_versao_secret)"; then
    IFS=$'\t' read -r nome estado <<< "$pol"
    if [ "$estado" = "DISABLED" ]; then marcar S2 "versão mais recente ${nome##*/} DISABLED"; fi
  else nao_lido S2 "as versões do secret"; fi

  if pol="$(pol_chave)"; then
    if ! politica_tem "$pol" "$ROLE_CHAVE" "$MEMBRO"; then marcar S5 "SA SEM $ROLE_CHAVE na chave"; fi
  else nao_lido S5 "a política da chave"; fi

  if pol="$(versao_primaria_chave)"; then
    IFS=$'\t' read -r nome estado <<< "$pol"
    if [ "$estado" = "DISABLED" ]; then marcar S6 "versão primária ${nome##*/} DISABLED"; fi
  else nao_lido S6 "a chave"; fi

  if pol="$(pol_projeto)"; then
    if politica_tem "$pol" "$ROLE_SECRET" "$MEMBRO"; then marcar S8 "SA tem $ROLE_SECRET no PROJETO"; fi
  else nao_lido S8 "a política do projeto"; fi

  if tem_token_creator; then marcar S9 "sua conta tem $ROLE_TOKEN na $SA_SEM_ACESSO_ID"; fi

  if [ "$ATIVOS" -eq 0 ] && [ "$INCERTOS" -eq 0 ]; then ok "nenhum cenário ativo"; fi
}

# Handler dos traps de ERR e INT. Não restaura sozinho: mostra o que está ativo e pergunta.
ao_interromper() {
  local motivo="$1" codigo="$2" resposta=""
  # Com set -E o ERR também dispara em subshells ($(...)): só o shell principal pergunta.
  if [ "${BASHPID:-$$}" != "$$" ]; then return 0; fi
  trap - ERR INT
  set +e
  printf '\n%s%s%s\n' "$VERMELHO" "$motivo" "$RESET"
  titulo "Cenários ativos"
  listar_ativos
  if [ "$ATIVOS" -eq 0 ] && [ "$INCERTOS" -eq 0 ]; then exit "$codigo"; fi
  read -r -p "  Restaurar agora? (s/N) " resposta || resposta=""
  case "$resposta" in
    s|S|sim|Sim|SIM)
      restaurar_tudo ;;
    *)
      aviso "Nada foi restaurado. Lembre de rodar depois: ./simulate-errors.sh restore (em security-demo/)" ;;
  esac
  exit "$codigo"
}

registrar_restore() {
  R_INICIO="-"; R_HORA="-"; R_ESPERA="-"; R_HTTP="-"; R_CODE="-"
  registrar "$1" "$(hora_completa) (restore)"
}

restaurar_tudo() {
  local nome estado restaurou_api=0
  titulo "Restaurar tudo (S1, S2, S5, S6, S8, S9) — $(hora_completa) (UTC-3)"

  # S1 e o binding do secret do S8 primeiro; o binding do projeto (S8) só depois.
  if ! tem_binding_secret; then
    titulo "S1/S8 — recolocar o binding no secret"
    if restaurar_binding_secret; then registrar_restore S1; restaurou_api=1; fi
  fi
  if tem_binding_projeto; then
    titulo "S8 — remover o binding do PROJETO"
    if remover_binding_projeto; then registrar_restore S8; restaurou_api=1; fi
  fi

  IFS=$'\t' read -r nome estado <<< "$(ultima_versao_secret)"
  if [ "$estado" = "DISABLED" ]; then
    titulo "S2 — reabilitar a versão ${nome##*/}"
    if executar gcloud secrets versions enable "${nome##*/}" --secret="$SECRET_NAME" --project="$PROJECT_ID"; then
      registrar_restore S2; restaurou_api=1
    fi
  fi

  if ! tem_binding_chave; then
    titulo "S5 — recolocar o binding na chave"
    if restaurar_binding_chave; then registrar_restore S5; restaurou_api=1; fi
  fi

  IFS=$'\t' read -r nome estado <<< "$(versao_primaria_chave)"
  if [ "$estado" = "DISABLED" ]; then
    titulo "S6 — reabilitar a versão primária ${nome##*/}"
    if executar gcloud kms keys versions enable "${nome##*/}" --key="$KEY" "${KMS_FLAGS[@]}"; then
      registrar_restore S6; restaurou_api=1
    fi
  fi

  if tem_token_creator; then
    titulo "S9 — remover $ROLE_TOKEN da sua conta na $SA_SEM_ACESSO_ID"
    if remover_token_creator; then registrar_restore S9; fi
  fi

  titulo "Estado após a restauração"
  mostrar_status

  requisitar GET /api/security/status
  if [ "$HTTP_CODE" = "200" ] && [ "$restaurou_api" -eq 1 ]; then
    titulo "Aguardando a propagação antes do caminho feliz"
    esperar GET /api/security/secret 200 - || true
    esperar POST /api/security/kms/roundtrip 200 - || true
  fi

  titulo "02-caminho-feliz.sh"
  if ! bash "$SCRIPT_DIR/02-caminho-feliz.sh"; then
    aviso "o caminho feliz reportou falhas (veja acima)."
  fi
}

menu() {
  local opcao=""
  verificar_recursos
  while :; do
    titulo "Cenários de erro — projeto $PROJECT_ID | SA $BACKEND_SA"
    cat <<'EOF'
  1  S1  IAM no secret (remover secretAccessor)        slides 8 e 12 (passos 7 e 8)
  2  S2  Versão do secret desabilitada                 slide 7
  3  S3  Versão inexistente / inválida                 slide 7
  4  S4  Rotação: nova versão sem redeploy             slide 7
  5  S5  IAM na chave (remover EncrypterDecrypter)     slide 10
  6  S6  Versão primária da chave desabilitada         slide 9
  7  S7  Ciphertext adulterado                         slide 10
  8  S8  Herança: role no PROJETO anula o controle     slides 4 e 6
  9  S9  Identidade errada (impersonação)              slides 4 e 5
  e  estado dos cenários
  r  restaurar tudo
  q  sair
EOF
    read -r -p "  Escolha: " opcao || exit 0
    case "$opcao" in
      1) cenario_s1 ;;
      2) cenario_s2 ;;
      3) cenario_s3 ;;
      4) cenario_s4 ;;
      5) cenario_s5 ;;
      6) cenario_s6 ;;
      7) cenario_s7 ;;
      8) cenario_s8 ;;
      9) cenario_s9 ;;
      e|E) mostrar_status ;;
      r|R) restaurar_tudo ;;
      q|Q) exit 0 ;;
      *) aviso "opção inválida" ;;
    esac
  done
}

case "${1:-menu}" in
  menu)    menu ;;
  status)  verificar_recursos; mostrar_status ;;
  restore) verificar_recursos; restaurar_tudo ;;
  *)
    echo "Uso: bash security-demo/simulate-errors.sh [status|restore]" >&2
    exit 2 ;;
esac
