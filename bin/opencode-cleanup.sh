#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${ENABLE_DOCKER_PRUNE:-1}" = "1" ] && command -v docker >/dev/null 2>&1; then
  docker builder prune -af >/dev/null 2>&1 || true
fi

"$DIR/opencode-db-compact.sh" || true
