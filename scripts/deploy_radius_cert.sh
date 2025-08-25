#!/usr/bin/env bash
set -euo pipefail

# プロジェクトルートを推定（このスクリプトの親ディレクトリ）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# When invoked from prod/ scripts, project root is one level up; otherwise two levels up
if [[ -d "${SCRIPT_DIR}/prod" ]]; then
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# .env を読み込んで FQDN を取得（未設定なら既定値）
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/.env"
fi
FQDN="${RADIUS_FQDN:-}"

if [[ -z "${FQDN}" ]]; then
    echo "[deploy] ERROR: RADIUS_FQDN が空です。.env に RADIUS_FQDN を設定してください。" >&2
    exit 1
fi

# 証明書ソース/配置先（CERT_SRC_DIR が指定されていれば優先）
SRC_LIVE_DIR="${CERT_SRC_DIR:-/etc/letsencrypt/live/${FQDN}}"
DEST_DIR="${PROJECT_ROOT}/radius/certs"

echo "[deploy] FQDN=${FQDN}"
echo "[deploy] Source: ${SRC_LIVE_DIR} -> Dest: ${DEST_DIR}"

if [[ ! -d "${SRC_LIVE_DIR}" ]]; then
	echo "[deploy] ERROR: ${SRC_LIVE_DIR} が見つかりません。Certbot発行後に実行してください。" >&2
	exit 1
fi

mkdir -p "${DEST_DIR}"

# FreeRADIUSの期待名に合わせて配置
# - server.pem: サーバ証明書 + 中間証明書（fullchain.pem）
# - server.key: サーバ秘密鍵
# - ca.pem:     中間チェーン（chain.pem）
install -m 0644 "${SRC_LIVE_DIR}/fullchain.pem" "${DEST_DIR}/server.pem"
install -m 0600 "${SRC_LIVE_DIR}/privkey.pem"   "${DEST_DIR}/server.key"
if [[ -f "${SRC_LIVE_DIR}/chain.pem" ]]; then
	install -m 0644 "${SRC_LIVE_DIR}/chain.pem" "${DEST_DIR}/ca.pem"
else
	# certbotのバージョンによっては chain.pem が無い場合があるため、fullchain から抽出せずそのままコピー
	install -m 0644 "${SRC_LIVE_DIR}/fullchain.pem" "${DEST_DIR}/ca.pem"
fi

echo "[deploy] Files installed: server.pem, server.key, ca.pem"

# コンテナ再起動（compose v2 前提）
if command -v docker >/dev/null 2>&1 && docker compose ls >/dev/null 2>&1; then
	echo "[deploy] Restarting freeradius container via docker compose..."
	docker compose restart freeradius || true
else
	echo "[deploy] NOTE: docker compose 未検出のため、FreeRADIUS再読込はスキップしました。"
fi

echo "[deploy] Done."


