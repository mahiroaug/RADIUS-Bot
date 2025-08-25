#!/usr/bin/env bash
set -euo pipefail

# Lambda runtime entrypoint calls: handler.lambda_handler
# Ensure certbot directories exist
mkdir -p /etc/letsencrypt /var/log/letsencrypt

python - <<'PY'
from handler import lambda_handler
print(lambda_handler({}, None))
PY


