#!/usr/bin/env bash
set -euo pipefail

# Purpose: Issue cert via Certbot (Route53) on dev machine and deploy to on-prem RADIUS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load env
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  # shellcheck disable=SC1090
  source "${PROJECT_ROOT}/.env"
fi

FQDN="${RADIUS_FQDN:-}"
REMOTE_HOST="${RADIUS_HOST:-}"
REMOTE_USER="${RADIUS_USER:-root}"

if [[ -z "${FQDN}" ]]; then
  echo "[prod] ERROR: RADIUS_FQDN is empty (.env)" >&2
  exit 1
fi
if [[ -z "${REMOTE_HOST}" ]]; then
  echo "[prod] ERROR: RADIUS_HOST is empty (.env or env var)" >&2
  exit 1
fi

echo "[prod] FQDN=${FQDN} Remote=${REMOTE_USER}@${REMOTE_HOST}"

# Ensure certbot exists
command -v certbot >/dev/null 2>&1 || { echo "[prod] ERROR: certbot not found" >&2; exit 1; }

# Issue/renew
sudo certbot certonly --dns-route53 -d "${FQDN}" -m admin@${FQDN#*.} --agree-tos --non-interactive || true

# Push to remote
CERT_SRC_DIR="/etc/letsencrypt/live/${FQDN}"
CERT_SRC_DIR="${CERT_SRC_DIR}" RADIUS_FQDN="${FQDN}" bash "${PROJECT_ROOT}/scripts/remote_push_radius_cert.sh"

echo "[prod] Completed."


