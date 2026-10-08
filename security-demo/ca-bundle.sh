#!/usr/bin/env bash
# Seminário Cloud IAM, Secret Manager e Cloud KMS — Triodelícia
# Sem slide próprio: contorna a inspeção TLS do antivírus nesta máquina.
#
# Problema: o Avast intercepta HTTPS e apresenta um certificado emitido pela raiz
# "Avast Web/Mail Shield Root". Essa raiz está no repositório do Windows (por isso o
# navegador e o curl funcionam), mas o gcloud valida com o bundle de CAs próprio do
# Python, que não a conhece — e todo comando morre com CERTIFICATE_VERIFY_FAILED.
#
# Solução: montar um bundle = cacert.pem do SDK + a(s) raiz(es) de interceptação do
# repositório do Windows, e apontar o gcloud para ele via variável de ambiente. Nada
# é alterado na configuração persistente do gcloud nem no antivírus.
#
# Uso (Git Bash) — precisa de `source`, senão o export morre com o subshell:
#   source security-demo/ca-bundle.sh            # monta se faltar e exporta
#   source security-demo/ca-bundle.sh --forcar    # remonta mesmo se já existir
#
# O bundle fica em security-demo/.local/ (ignorado pelo git): são certificados desta
# máquina, não pertencem ao repositório.

# Sem `set -e`: este arquivo é lido com `source`, e um erro não deve fechar o terminal
# do usuário. Cada passo trata o próprio erro e usa `return`.

_ca_bundle_main() {
  local forcar=0 arg
  for arg in "$@"; do
    case "$arg" in
      --forcar|-f) forcar=1 ;;
      *) printf 'ca-bundle: opção desconhecida: %s (use --forcar)\n' "$arg" >&2; return 2 ;;
    esac
  done

  # Padrão do "subject" da raiz de interceptação. Trocou de antivírus? Sobrescreva:
  #   CA_PADRAO="Zscaler" source security-demo/ca-bundle.sh --forcar
  local padrao="${CA_PADRAO:-Avast}"

  local dir_script dir_local destino
  dir_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  dir_local="$dir_script/.local"
  destino="$dir_local/ca-bundle.pem"

  # Já montado e sem --forcar: só reexporta (caminho rápido do dia a dia).
  if [ "$forcar" -eq 0 ] && [ -s "$destino" ]; then
    printf 'ca-bundle: bundle já existia, reutilizado (--forcar remonta).\n'
    _ca_bundle_exportar "$destino"
    return $?
  fi

  local gcloud_bin sdk_root base_certs
  gcloud_bin="$(command -v gcloud)" || {
    printf 'ca-bundle: gcloud não está no PATH.\n' >&2; return 1
  }
  # .../google-cloud-sdk/bin/gcloud -> .../google-cloud-sdk
  sdk_root="$(cd "$(dirname "$(dirname "$gcloud_bin")")" && pwd)" || return 1
  base_certs="$sdk_root/lib/third_party/certifi/cacert.pem"
  if [ ! -s "$base_certs" ]; then
    printf 'ca-bundle: não achei o cacert.pem do SDK em:\n  %s\n' "$base_certs" >&2
    return 1
  fi

  mkdir -p "$dir_local" || return 1

  # Exporta a(s) raiz(es) do repositório do Windows. O PowerShell vai para um arquivo
  # em vez de -Command: evita camadas de escape entre o Git Bash e o PowerShell.
  local ps1 pem_extra
  ps1="$dir_local/exportar-raiz.ps1"
  pem_extra="$dir_local/raiz-interceptacao.pem"

  cat > "$ps1" <<'FIM_PS1'
$ErrorActionPreference = 'Stop'
$padrao  = $args[0]
$destino = $args[1]

$certs = Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
         Where-Object { $_.Subject -like "*$padrao*" } |
         Sort-Object -Property Thumbprint -Unique

if (-not $certs) {
  Write-Output "SEM_CERTIFICADO"
  exit 3
}

$linhas = @()
foreach ($c in $certs) {
  # Comentários fora dos marcadores BEGIN/END são ignorados por quem lê o bundle.
  $linhas += "# $($c.Subject)"
  $linhas += "# thumbprint $($c.Thumbprint) | expira $($c.NotAfter.ToString('yyyy-MM-dd'))"
  $linhas += "-----BEGIN CERTIFICATE-----"
  $linhas += [Convert]::ToBase64String($c.RawData, 'InsertLineBreaks')
  $linhas += "-----END CERTIFICATE-----"
  Write-Output "OK $($c.Thumbprint)"
}
Set-Content -Path $destino -Value $linhas -Encoding ascii
FIM_PS1

  local ps1_win destino_extra_win saida_ps
  ps1_win="$(cygpath -m "$ps1")"
  destino_extra_win="$(cygpath -m "$pem_extra")"

  saida_ps="$(powershell.exe -NoProfile -ExecutionPolicy Bypass \
                -File "$ps1_win" "$padrao" "$destino_extra_win" 2>&1 | tr -d '\r')"
  if [ ! -s "$pem_extra" ]; then
    printf 'ca-bundle: não consegui exportar a raiz "%s" do repositório do Windows.\n' "$padrao" >&2
    printf '  Saída do PowerShell:\n' >&2
    printf '    %s\n' "$saida_ps" >&2
    printf '  Se o antivírus não for o Avast, rode com CA_PADRAO=<nome> (ex.: Zscaler, Kaspersky, ESET).\n' >&2
    rm -f "$ps1"
    return 1
  fi
  rm -f "$ps1"

  # Bundle final: base do SDK primeiro, raiz de interceptação depois.
  if ! cat "$base_certs" "$pem_extra" > "$destino"; then
    printf 'ca-bundle: falhou ao gravar %s\n' "$destino" >&2
    return 1
  fi

  local quantas
  quantas="$(grep -c 'BEGIN CERTIFICATE' "$pem_extra")"
  printf 'ca-bundle: montado (%s raiz(es) "%s" + cacert.pem do SDK).\n' "$quantas" "$padrao"

  _ca_bundle_exportar "$destino"
}

# Exporta a variável que o gcloud lê (equivale a core/custom_ca_certs_file, mas só
# neste shell). O gcloud é um Python do Windows: precisa de C:/... e não de /c/...
_ca_bundle_exportar() {
  local caminho_win
  caminho_win="$(cygpath -m "$1")" || return 1
  export CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="$caminho_win"
  printf 'ca-bundle: CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE=%s\n' "$caminho_win"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Executado direto: monta o bundle, mas o export não sobrevive ao fim do processo.
  _ca_bundle_main "$@"
  _rc=$?
  printf '\nca-bundle: ATENÇÃO — rodado sem `source`, o export não valeu para o seu shell.\n' >&2
  printf '  Rode:  source security-demo/ca-bundle.sh\n' >&2
  exit "$_rc"
fi

_ca_bundle_main "$@"
