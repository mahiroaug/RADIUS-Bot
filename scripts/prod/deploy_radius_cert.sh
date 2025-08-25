#!/usr/bin/env bash
set -euo pipefail

# Thin wrapper to call project-level deploy script from prod directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
bash "${PROJECT_ROOT}/scripts/deploy_radius_cert.sh"


