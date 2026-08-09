#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${DAIB_COMPOSE_FILE:-${REPO_ROOT}/deploy/compose.orange-pi-5-max.yml}"
ENV_FILE="${DAIB_ENV_FILE:-${REPO_ROOT}/deploy/.env}"
CHECK_SECONDS="${CHECK_SECONDS:-8}"
REALSENSE_USB_ID="${REALSENSE_USB_ID:-8086:0b3a}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check-seconds N]

Start the Orange Pi algorithm and sensor-driver services, then validate the
D435i and MID-70 streams. Configuration is read from:
  ${ENV_FILE}
EOF
}

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --check-seconds)
      (($# >= 2)) || fail "--check-seconds requires a value"
      CHECK_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$CHECK_SECONDS" =~ ^[0-9]+$ ]] \
  || fail "--check-seconds must be an integer"
(( CHECK_SECONDS >= 3 && CHECK_SECONDS <= 60 )) \
  || fail "--check-seconds must be between 3 and 60"

[[ "$(uname -s)" == "Linux" ]] \
  || fail "this script must run on the Orange Pi Linux host"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) fail "expected an ARM64 host, found $(uname -m)" ;;
esac

command -v docker >/dev/null || fail "docker is not installed"
command -v lsusb >/dev/null || fail "lsusb is not installed"
docker info >/dev/null 2>&1 || fail "the Docker daemon is not reachable"
[[ -r "$COMPOSE_FILE" ]] || fail "compose file is not readable: ${COMPOSE_FILE}"
[[ -r "$ENV_FILE" ]] || fail "runtime environment file is not readable: ${ENV_FILE}"
lsusb -d "$REALSENSE_USB_ID" >/dev/null 2>&1 \
  || fail "D435i USB device ${REALSENSE_USB_ID} is not connected"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
elif command -v docker-compose >/dev/null; then
  COMPOSE=(docker-compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
else
  fail "Docker Compose is not installed"
fi

LOCK_DIR=/tmp/daib-start-mid70-d435i.lock
mkdir "$LOCK_DIR" 2>/dev/null \
  || fail "another MID-70/D435i startup is already running"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

echo "[1/5] Validating Compose configuration"
"${COMPOSE[@]}" config --quiet

echo "[2/5] Starting ROS master and algorithm service"
"${COMPOSE[@]}" up -d --no-build algorithm

echo "[3/5] Recreating driver service to refresh USB devices"
"${COMPOSE[@]}" up -d --no-build --no-deps --force-recreate drivers

algorithm_id="$("${COMPOSE[@]}" ps -q algorithm)"
drivers_id="$("${COMPOSE[@]}" ps -q drivers)"
[[ -n "$algorithm_id" ]] || fail "algorithm container was not created"
[[ -n "$drivers_id" ]] || fail "drivers container was not created"

wait_for_running() {
  local container_id="$1"
  local service="$2"
  local state
  for _ in $(seq 1 30); do
    state="$(docker inspect -f '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
    [[ "$state" == "running" ]] && return 0
    [[ "$state" == "exited" || "$state" == "dead" ]] && break
    sleep 1
  done
  "${COMPOSE[@]}" logs --tail 100 "$service" >&2 || true
  fail "${service} service is not running"
}

wait_for_running "$algorithm_id" algorithm
wait_for_running "$drivers_id" drivers

ROS_ENV='source /opt/ros/noetic/setup.bash; source /opt/daib_ws/devel/setup.bash; export ROS_MASTER_URI=http://127.0.0.1:11311; export ROS_HOSTNAME=127.0.0.1; unset ROS_IP'

echo "[4/5] Waiting for ROS master"
master_ready=false
for _ in $(seq 1 30); do
  if "${COMPOSE[@]}" exec -T algorithm bash -lc \
      "$ROS_ENV; rosparam list >/dev/null 2>&1"; then
    master_ready=true
    break
  fi
  sleep 1
done
[[ "$master_ready" == "true" ]] || {
  "${COMPOSE[@]}" logs --tail 100 algorithm drivers >&2 || true
  fail "ROS master did not become ready"
}

"${COMPOSE[@]}" exec -T algorithm bash -lc \
  "$ROS_ENV; rosparam set /use_sim_time false; printf 'y\\n' | rosnode cleanup >/dev/null 2>&1 || true"

echo "[5/5] Validating sensor rates and timestamp alignment for ${CHECK_SECONDS}s"
if ! "${COMPOSE[@]}" exec -T algorithm bash -lc \
    "$ROS_ENV; python3 /opt/daib_ws/src/fast_livo/scripts/check_sensor_timing.py --duration '$CHECK_SECONDS' --validate"; then
  "${COMPOSE[@]}" logs --tail 100 drivers >&2 || true
  fail "sensor timing validation failed"
fi

lidar_type="$("${COMPOSE[@]}" exec -T algorithm bash -lc \
  "$ROS_ENV; rostopic type /livox/lidar")"
[[ "$lidar_type" == "livox_ros_driver/CustomMsg" ]] \
  || fail "unexpected /livox/lidar type: ${lidar_type}"

echo
echo "[PASS] D435i and MID-70 are ready"
echo "  image: /camera/color/image_raw"
echo "  imu:   /camera/imu"
echo "  lidar: /livox/lidar (${lidar_type})"
echo "  stack: ${COMPOSE_FILE}"
