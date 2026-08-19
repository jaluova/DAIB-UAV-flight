#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${DAIB_COMPOSE_FILE:-${REPO_ROOT}/deploy/compose.orange-pi-5-max.yml}"
ENV_FILE="${DAIB_ENV_FILE:-${REPO_ROOT}/deploy/.env}"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
elif command -v docker-compose >/dev/null; then
  COMPOSE=(docker-compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
else
  echo "[FAIL] Docker Compose is not installed" >&2
  exit 1
fi

echo "[1/2] Stopping Compose algorithm, driver and ROS Master services"
pkill -TERM -f '[d]aib_planning_watchdog.sh' 2>/dev/null || true
"${COMPOSE[@]}" stop algorithm drivers roscore >/dev/null 2>&1 || true

echo "[2/2] Stopping legacy standalone LIVO/Foxglove containers"
for name in fast-livo foxglove daib-fast-livo daib-foxglove; do
  docker stop "$name" >/dev/null 2>&1 || true
done

echo
echo "[PASS] DAIB algorithm, drivers and Foxglove services are stopped"
