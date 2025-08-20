#!/usr/bin/env bash
set -euo pipefail

# 使い方:
#  RADIUS_FQDN=radius.web3sst.com \
#  RADIUS_HOST=radius.example.internal \
#  RADIUS_USER=ubuntu \
#  CERT_SRC_DIR=$HOME/.config/letsencrypt/live/radius.web3sst.com \
#  bash scripts/remote_push_radius_cert.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# .env があれば読み込む
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  # shellcheck disable=SC1090
  source "${PROJECT_ROOT}/.env"
fi

FQDN="${RADIUS_FQDN:-}"
REMOTE_HOST="${RADIUS_HOST:-}"
REMOTE_USER="${RADIUS_USER:-root}"
CERT_SRC_DIR="${CERT_SRC_DIR:-$HOME/.config/letsencrypt/live/${FQDN}}"

if [[ -z "${FQDN}" ]]; then
  echo "[push] ERROR: RADIUS_FQDN が空です" >&2
  exit 1
fi
if [[ -z "${REMOTE_HOST}" ]]; then
  echo "[push] ERROR: RADIUS_HOST が空です" >&2
  exit 1
fi

echo "[push] FQDN=${FQDN}"
echo "[push] CERT_SRC_DIR=${CERT_SRC_DIR}"
echo "[push] Remote: ${REMOTE_USER}@${REMOTE_HOST}"

if [[ ! -d "${CERT_SRC_DIR}" ]]; then
  echo "[push] ERROR: ${CERT_SRC_DIR} が見つかりません。まずcertbotで発行してください。" >&2
  exit 1
fi

TMP_DIR="/tmp/radius_cert_${FQDN}_$(date +%s)"
mkdir -p "${TMP_DIR}"
cp -f "${CERT_SRC_DIR}/fullchain.pem" "${TMP_DIR}/server.pem"
cp -f "${CERT_SRC_DIR}/privkey.pem"   "${TMP_DIR}/server.key"
cp -f "${CERT_SRC_DIR}/chain.pem"     "${TMP_DIR}/ca.pem" 2>/dev/null || cp -f "${CERT_SRC_DIR}/fullchain.pem" "${TMP_DIR}/ca.pem"

# 転送
scp -q "${TMP_DIR}/server.pem" "${TMP_DIR}/server.key" "${TMP_DIR}/ca.pem" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/"

# リモート側で配置＆再起動
ssh -q "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<'EOSSH'
set -euo pipefail
PROJECT_DIR="/workspaces/RADIUS-Bot"
DEST_DIR="${PROJECT_DIR}/radius/certs"
mkdir -p "${DEST_DIR}"
install -m 0644 /tmp/server.pem "${DEST_DIR}/server.pem"
install -m 0600 /tmp/server.key "${DEST_DIR}/server.key"
install -m 0644 /tmp/ca.pem     "${DEST_DIR}/ca.pem"
rm -f /tmp/server.pem /tmp/server.key /tmp/ca.pem

if command -v docker >/dev/null 2>&1 && docker compose ls >/dev/null 2>&1; then
  docker compose restart freeradius || true
fi
echo "[push] Remote deploy done"
EOSSH

rm -rf "${TMP_DIR}"
echo "[push] Done"


