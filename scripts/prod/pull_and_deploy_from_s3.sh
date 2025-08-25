#!/usr/bin/env bash
set -euo pipefail

# Purpose: Pull certs from S3 (public GET with IP allowlist) and deploy them to FreeRADIUS.
# Features:
#  - ETag/Last-Modified check to avoid unnecessary reloads
#  - Atomic replace via deploy_radius_cert.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load .env if present (KEY=VALUE lines only)
ENV_FILE="${PROJECT_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  echo "[pull] 環境ファイルを読み込みます: ${ENV_FILE}"
  TMP_ENV=$(mktemp)
  awk 'BEGIN{IGNORECASE=0} \
      /^[[:space:]]*#/ {next} \
      /^[[:space:]]*$/ {next} \
      /^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/ {print} \
  ' "${ENV_FILE}" > "${TMP_ENV}"
  set -a
  # shellcheck disable=SC1090
  . "${TMP_ENV}"
  set +a
  rm -f "${TMP_ENV}"
fi

echo "[pull] Config:"
echo "  CERT_URL_SERVER_PEM=${CERT_URL_SERVER_PEM}"
echo "  CERT_URL_SERVER_KEY=${CERT_URL_SERVER_KEY}"
echo "  CERT_URL_CA_PEM=${CERT_URL_CA_PEM}"
[[ -n "${FORCE:-}" ]] && echo "[pull] FORCE=1 (cache bypass)"

# Expected env vars (URLs can be S3 public objects with IP allowlist, or presigned URLs)
: "${CERT_URL_SERVER_PEM:?CERT_URL_SERVER_PEM is required (URL to server.pem/fullchain.pem)}"
: "${CERT_URL_SERVER_KEY:?CERT_URL_SERVER_KEY is required (URL to server.key/privkey.pem)}"
: "${CERT_URL_CA_PEM:?CERT_URL_CA_PEM is required (URL to ca.pem/chain or fullchain)}"

TMP_DIR="/tmp/radius_certs_$(date +%s)"
STATE_DIR="${PROJECT_ROOT}/.state"
mkdir -p "${STATE_DIR}"
mkdir -p "${TMP_DIR}"

echo "[pull] Checking remote metadata (ETag/Last-Modified)"
etag_pem=$(curl -fsI "${CERT_URL_SERVER_PEM}" | awk -F': ' 'tolower($1)=="etag"{gsub("\r","",$2);print $2}') || true
lm_pem=$(curl -fsI "${CERT_URL_SERVER_PEM}" | awk -F': ' 'tolower($1)=="last-modified"{gsub("\r","",$2);print $2}') || true
etag_key=$(curl -fsI "${CERT_URL_SERVER_KEY}" | awk -F': ' 'tolower($1)=="etag"{gsub("\r","",$2);print $2}') || true
lm_key=$(curl -fsI "${CERT_URL_SERVER_KEY}" | awk -F': ' 'tolower($1)=="last-modified"{gsub("\r","",$2);print $2}') || true
etag_ca=$(curl -fsI "${CERT_URL_CA_PEM}" | awk -F': ' 'tolower($1)=="etag"{gsub("\r","",$2);print $2}') || true
lm_ca=$(curl -fsI "${CERT_URL_CA_PEM}" | awk -F': ' 'tolower($1)=="last-modified"{gsub("\r","",$2);print $2}') || true
echo "[pull] remote headers:"
echo "  server.pem  ETag=${etag_pem}  Last-Modified=${lm_pem}"
echo "  server.key  ETag=${etag_key}  Last-Modified=${lm_key}"
echo "  ca.pem      ETag=${etag_ca}  Last-Modified=${lm_ca}"

cache_file="${STATE_DIR}/s3_cert_meta"
prev_etag_pem=""; prev_etag_key=""; prev_etag_ca=""; prev_lm_pem=""; prev_lm_key=""; prev_lm_ca=""
if [[ -f "${cache_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cache_file}"
fi
[[ -f "${cache_file}" ]] && echo "[pull] cache found: ${cache_file}" || echo "[pull] cache not found (first run)"

# Skip only when: not forced AND cache exists AND current headers present AND unchanged
if [[ -z "${FORCE:-}" && -f "${cache_file}" ]]; then
  current_concat="${etag_pem}${lm_pem}${etag_key}${lm_key}${etag_ca}${lm_ca}"
  if [[ -n "${current_concat}" && "${current_concat}" == "${prev_etag_pem}${prev_lm_pem}${prev_etag_key}${prev_lm_key}${prev_etag_ca}${prev_lm_ca}" ]]; then
    echo "[pull] No change detected (ETag/Last-Modified). Skipping download and reload."
    exit 0
  fi
fi

echo "[pull] Downloading cert artifacts to ${TMP_DIR}"
curl -fSL --retry 3 --retry-delay 2 "${CERT_URL_SERVER_PEM}" -o "${TMP_DIR}/server.pem"
curl -fSL --retry 3 --retry-delay 2 "${CERT_URL_SERVER_KEY}" -o "${TMP_DIR}/server.key"
curl -fSL --retry 3 --retry-delay 2 "${CERT_URL_CA_PEM}"     -o "${TMP_DIR}/ca.pem"
echo "[pull] downloaded sizes:"
echo "  server.pem: $(wc -c < "${TMP_DIR}/server.pem" 2>/dev/null || echo 0) bytes"
echo "  server.key: $(wc -c < "${TMP_DIR}/server.key" 2>/dev/null || echo 0) bytes"
echo "  ca.pem:     $(wc -c < "${TMP_DIR}/ca.pem" 2>/dev/null || echo 0) bytes"

# Map downloaded filenames to certbot live layout expected by deploy script
if [[ -z "${RADIUS_FQDN:-}" ]]; then
  echo "[pull] ERROR: RADIUS_FQDN is empty. Set it in .env" >&2
  exit 1
fi
LIVE_DIR="${TMP_DIR}/live/${RADIUS_FQDN}"
mkdir -p "${LIVE_DIR}"
cp -f "${TMP_DIR}/server.pem" "${LIVE_DIR}/fullchain.pem"
cp -f "${TMP_DIR}/server.key" "${LIVE_DIR}/privkey.pem"
cp -f "${TMP_DIR}/ca.pem"     "${LIVE_DIR}/chain.pem" || true
echo "[pull] prepared live dir: ${LIVE_DIR} (fullchain/privkey/chain)"

# Basic sanity checks
[[ -s "${TMP_DIR}/server.pem" ]] || { echo "[pull] ERROR: server.pem empty" >&2; exit 1; }
[[ -s "${TMP_DIR}/server.key" ]] || { echo "[pull] ERROR: server.key empty" >&2; exit 1; }
[[ -s "${TMP_DIR}/ca.pem" ]]     || { echo "[pull] ERROR: ca.pem empty" >&2; exit 1; }

# Deploy
echo "[pull] Deploying certs via deploy_radius_cert.sh"
if CERT_SRC_DIR="${LIVE_DIR}" bash "${PROJECT_ROOT}/scripts/deploy_radius_cert.sh"; then
  echo "[pull] Deploy completed"
else
  echo "[pull] ERROR: deploy script failed" >&2
  exit 1
fi

# Save new metadata
cat > "${cache_file}" <<EOF
prev_etag_pem='${etag_pem}'
prev_lm_pem='${lm_pem}'
prev_etag_key='${etag_key}'
prev_lm_key='${lm_key}'
prev_etag_ca='${etag_ca}'
prev_lm_ca='${lm_ca}'
EOF
echo "[pull] cache updated: ${cache_file}"

# Cleanup
rm -rf "${TMP_DIR}"
echo "[pull] Done $(date -u +%Y-%m-%dT%H:%M:%SZ)"


