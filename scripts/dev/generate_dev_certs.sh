#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CERT_DIR="${PROJ_ROOT}/radius/certs"

# .env 読み込み（任意）
if [[ -f "${PROJ_ROOT}/.env" ]]; then
  # shellcheck disable=SC1090
  source "${PROJ_ROOT}/.env"
fi
FQDN="${RADIUS_FQDN:-radius.local}"

echo "[dev] Generating self-signed dev certs -> ${CERT_DIR} (FQDN=${FQDN})"
mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

# CA鍵/証明書
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 365 -key ca.key -out ca.pem -subj "/C=JP/ST=Tokyo/L=Tokyo/O=RadiusDev/CN=RadiusDev-CA"

# サーバ鍵
openssl genrsa -out server.key 2048

# CSR（SAN付き）
openssl req -new -key server.key -out server.csr \
  -subj "/C=JP/ST=Tokyo/L=Tokyo/O=RadiusDev/CN=${FQDN}" \
  -addext "subjectAltName = DNS:${FQDN}"

# サーバ証明書（SAN維持）
openssl x509 -req -days 365 -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem \
  -extfile <(printf "[v3_req]\nsubjectAltName=DNS:%s\n" "${FQDN}") -extensions v3_req

# DHパラメータ
openssl dhparam -out dh 2048

# 権限
chmod 600 server.key ca.key
chmod 644 server.pem ca.pem server.csr dh

echo "[dev] Done. Files in radius/certs:"
ls -l


