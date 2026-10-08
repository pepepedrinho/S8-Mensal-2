#!/usr/bin/env bash
# Seminário Cloud IAM, Secret Manager e Cloud KMS — Triodelícia
# Slide 7 — segredo fora do código: gera o "antes" e o "depois" da evidência 01.
#
# Busca credenciais escritas no código: árvore de trabalho + histórico do git.
# Saída: Markdown em stdout. Todo valor literal sai mascarado (***); os valores
# encontrados só são usados internamente (comparação por hash), nunca exibidos.
#
# Uso (Git Bash / Linux / macOS):
#   bash security-demo/buscar-credenciais.sh "Antes" >> security-demo/evidencias/01-segredos-no-codigo.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TITULO="${1:-Busca}"

# URI com usuário:senha | chave=valor de senha/segredo | chave PEM | API key Google | token GitHub
PADRAO="[a-z][a-z0-9+.-]*://[^/@:[:space:]\"'\`]+:[^/@[:space:]\"'\`]+@"
PADRAO+="|(password|passwd|senha|secret|api_?key|private_?key|access_?token|auth_?token)[a-z0-9_]*[\"']?[[:space:]]*[:=]"
PADRAO+="|-----BEGIN [a-z ]*private key|aiza[0-9a-z_-]{35}|ghp_[0-9a-z]{36}|\"private_key_id\""

# Fora da busca: este diretório (script e evidências) e lockfiles (hashes de integridade).
PATHSPEC=(-- . ':(exclude)security-demo' ':(exclude,glob)**/package-lock.json')

mascarar() {
  sed -E \
    -e "s#(://[^/@:[:space:]\"'\`]+:)[^\$/@[:space:]\"'\`][^/@[:space:]\"'\`]*@#\1***@#g" \
    -e "s#((password|passwd|senha|secret|api_?key|private_?key|access_?token|auth_?token)[a-z0-9_]*[\"']?[[:space:]]*[:=][[:space:]]*[\"']?)[^\$?\"'[:space:],}][^\"'[:space:],}]*#\1***#Ig" \
    -e "s#(-----BEGIN [a-z ]*private key-----).*#\1 ***#Ig" \
    -e "s#aiza[0-9a-z_-]{35}#AIza***#Ig" \
    -e "s#ghp_[0-9a-z]{36}#ghp_***#Ig"
}

# Uso interno: valores literais de uma linha crua. Ignora referências ($VAR, ${VAR}) e a
# mensagem de ${VAR:?msg}; o padrão de ${VAR:-padrão} continua contando como literal.
extrair_valores() {
  local linha="$1"
  {
    printf '%s\n' "$linha" | grep -oiE "://[^/@:[:space:]\"'\`]+:[^/@[:space:]\"'\`]+@" \
      | sed -E 's#^://[^:]*:##; s#@$##' || true
    printf '%s\n' "$linha" \
      | grep -oiE "(password|passwd|senha|secret|api_?key|private_?key|access_?token|auth_?token)[a-z0-9_]*[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[^\"'[:space:],}]+" \
      | sed -E "s#^[^:=]*[:=][[:space:]]*[\"']?##" || true
  } | grep -vE '^[$?]' | awk 'length($0) >= 3' || true
}

# Máscara + trava de segurança: se algum valor literal sobreviver, a linha é omitida.
trecho_seguro() {
  local linha="$1" mascarada valor
  mascarada="$(printf '%s\n' "$linha" | mascarar)"
  while IFS= read -r valor; do
    [ -z "$valor" ] && continue
    if [[ "$mascarada" == *"$valor"* ]]; then
      printf '%s' "[linha omitida: mascaramento não cobriu o valor]"
      return
    fi
  done < <(extrair_valores "$linha")
  mascarada="$(printf '%s' "$mascarada" | sed -E 's/^[[:space:]]+//; s/\|/\\|/g')"
  if [ "${#mascarada}" -gt 140 ]; then
    mascarada="${mascarada:0:140}…"
  fi
  printf '%s' "$mascarada"
}

classificar() {
  local arquivo="$1" trecho="$2"
  if [[ "$arquivo" == *.env.example ]]; then
    printf 'exemplo (valor falso)'
  elif [[ "$trecho" == *"***"* ]]; then
    printf '**valor literal**'
  elif [[ "$trecho" == *'${'* || "$trecho" == *'$('* || "$trecho" == *process.env* ]]; then
    printf 'referência a variável'
  else
    printf 'sem valor literal'
  fi
}

contar_distintos() {  # stdin: linhas cruas; stdout: nº de valores literais distintos
  local linha
  while IFS= read -r linha; do
    extrair_valores "$linha"
  done | while IFS= read -r v; do printf '%s' "$v" | sha256sum | cut -d' ' -f1; done \
    | sort -u | wc -l | tr -d ' '
}

cd "$REPO_DIR"

HEAD_CURTO="$(git rev-parse --short HEAD)"
if [ -n "$(git status --porcelain)" ]; then PENDENTE="sim"; else PENDENTE="não"; fi

echo "## $TITULO"
echo
echo "- Data da busca: $(date '+%Y-%m-%d %H:%M')"
echo "- HEAD: \`$HEAD_CURTO\` — alterações não commitadas na árvore: $PENDENTE"
echo "- Padrões: URI com \`usuário:senha@\`; \`password/secret/api_key/token = valor\`;"
echo "  chave privada PEM; API key do Google (\`AIza…\`); token do GitHub (\`ghp_…\`)."
echo "- Fora da busca: \`security-demo/\` (este script e as evidências) e \`package-lock.json\`."
echo

# --- Árvore de trabalho -------------------------------------------------------
ARVORE="$(git grep -nIiE --untracked "$PADRAO" "${PATHSPEC[@]}" || true)"
LITERAIS_ARVORE=0
echo "### Árvore de trabalho (versionados + novos não ignorados)"
echo
if [ -z "$ARVORE" ]; then
  echo "Nenhuma ocorrência."
else
  echo "| Arquivo | Linha | Trecho (mascarado) | Classificação |"
  echo "|---|---|---|---|"
  while IFS= read -r hit; do
    arquivo="${hit%%:*}"; resto="${hit#*:}"
    num="${resto%%:*}"; conteudo="${resto#*:}"
    trecho="$(trecho_seguro "$conteudo")"
    classe="$(classificar "$arquivo" "$trecho")"
    [ "$classe" = "**valor literal**" ] && LITERAIS_ARVORE=$((LITERAIS_ARVORE + 1))
    echo "| \`$arquivo\` | $num | \`\` $trecho \`\` | $classe |"
  done <<< "$ARVORE"
fi
echo

echo "### Arquivos .env presentes no disco e ignorados pelo git (só nomes)"
echo
ENVS="$(git ls-files --others --ignored --exclude-standard | grep -E '(^|/)\.env' || true)"
if [ -z "$ENVS" ]; then
  echo "Nenhum."
else
  while IFS= read -r f; do echo "- \`$f\`"; done <<< "$ENVS"
fi
echo

# --- Histórico ----------------------------------------------------------------
declare -A COMMITS LINHA
ORDEM=()
HIST_CRU=""
while IFS= read -r c; do
  hits="$(git grep -nIiE "$PADRAO" "$c" "${PATHSPEC[@]}" || true)"
  [ -z "$hits" ] && continue
  while IFS= read -r hit; do
    resto="${hit#*:}"                       # remove "<sha>:"
    arquivo="${resto%%:*}"; resto="${resto#*:}"
    num="${resto%%:*}"; conteudo="${resto#*:}"
    HIST_CRU+="$conteudo"$'\n'
    chave="$arquivo|$(trecho_seguro "$conteudo")"
    if [ -z "${COMMITS[$chave]+x}" ]; then
      ORDEM+=("$chave"); COMMITS[$chave]="${c:0:7}"; LINHA[$chave]="$num"
    else
      COMMITS[$chave]+=", ${c:0:7}"
    fi
  done <<< "$hits"
done < <(git rev-list --all)

echo "### Histórico do git ($(git rev-list --all | wc -l | tr -d ' ') commits, todas as refs)"
echo
if [ "${#ORDEM[@]}" -eq 0 ]; then
  echo "Nenhuma ocorrência."
else
  echo "| Arquivo | Linha* | Trecho (mascarado) | Commits em que aparece (mais recente → mais antigo) |"
  echo "|---|---|---|---|"
  for chave in "${ORDEM[@]}"; do
    echo "| \`${chave%%|*}\` | ${LINHA[$chave]} | \`\` ${chave#*|} \`\` | ${COMMITS[$chave]} |"
  done
  echo
  echo "\\* Linha no commit mais recente em que o trecho aparece."
fi
echo

echo "### Resumo"
echo
echo "- Ocorrências com valor literal na árvore de trabalho: **$LITERAIS_ARVORE**"
echo "- Valores literais distintos na árvore, sem contar \`.env.example\` (comparados por hash, não exibidos): $(printf '%s' "$ARVORE" | grep -vE '^[^:]*\.env\.example:' | sed -E 's/^[^:]*:[^:]*://' | contar_distintos)"
echo "- Valores literais distintos no histórico (comparados por hash, não exibidos): $(printf '%s' "$HIST_CRU" | contar_distintos)"
echo
