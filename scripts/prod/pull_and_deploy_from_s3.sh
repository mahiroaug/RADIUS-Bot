#!/usr/bin/env bash
set -euo pipefail

# Purpose: Pull certs from S3 (public GET with IP allowlist) and deploy them to FreeRADIUS.
# Features:
#  - ETag/Last-Modified check to avoid unnecessary reloads
#  - Atomic replace via deploy_radius_cert.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load .env if present
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  # shellcheck disable=SC1090
  source "${PROJECT_ROOT}/.env"
fi

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

cache_file="${STATE_DIR}/s3_cert_meta"
prev_etag_pem=""; prev_etag_key=""; prev_etag_ca=""; prev_lm_pem=""; prev_lm_key=""; prev_lm_ca=""
if [[ -f "${cache_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cache_file}"
fi

if [[ "${etag_pem}${lm_pem}${etag_key}${lm_key}${etag_ca}${lm_ca}" == "${prev_etag_pem}${prev_lm_pem}${prev_etag_key}${prev_lm_key}${prev_etag_ca}${prev_lm_ca}" ]]; then
  echo "[pull] No change detected (ETag/Last-Modified). Skipping download and reload."
  exit 0
fi

echo "[pull] Downloading cert artifacts to ${TMP_DIR}"
curl -fSL --retry 3 --retry-delay 2 "${CERT_URL_SERVER_PEM}" -o "${TMP_DIR}/server.pem"
curl -fSL --retry 3 --retry-delay 2 "${CERT_URL_SERVER_KEY}" -o "${TMP_DIR}/server.key"
curl -fSL --retry 3 --retry-delay 2 "${CERT_URL_CA_PEM}"     -o "${TMP_DIR}/ca.pem"

# Basic sanity checks
[[ -s "${TMP_DIR}/server.pem" ]] || { echo "[pull] ERROR: server.pem empty" >&2; exit 1; }
[[ -s "${TMP_DIR}/server.key" ]] || { echo "[pull] ERROR: server.key empty" >&2; exit 1; }
[[ -s "${TMP_DIR}/ca.pem" ]]     || { echo "[pull] ERROR: ca.pem empty" >&2; exit 1; }

# Deploy
echo "[pull] Deploying certs via deploy_radius_cert.sh"
CERT_SRC_DIR="${TMP_DIR}" bash "${PROJECT_ROOT}/scripts/deploy_radius_cert.sh"

# Save new metadata
cat > "${cache_file}" <<EOF
prev_etag_pem='${etag_pem}'
prev_lm_pem='${lm_pem}'
prev_etag_key='${etag_key}'
prev_lm_key='${lm_key}'
prev_etag_ca='${etag_ca}'
prev_lm_ca='${lm_ca}'
EOF

# Cleanup
rm -rf "${TMP_DIR}"
echo "[pull] Done"


