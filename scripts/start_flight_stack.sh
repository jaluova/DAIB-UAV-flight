#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${DAIB_COMPOSE_FILE:-${REPO_ROOT}/deploy/compose.orange-pi-5-max.yml}"
ENV_FILE="${DAIB_ENV_FILE:-${REPO_ROOT}/deploy/.env}"
CHECK_SECONDS="${CHECK_SECONDS:-8}"
CAMERA_RATE="${FOXGLOVE_CAMERA_RATE:-6.0}"
FOXGLOVE_PORT="${FOXGLOVE_PORT:-8765}"
SEND_BUFFER_LIMIT="${FOXGLOVE_SEND_BUFFER_LIMIT:-4000000}"
CAMERA_SOURCE_TOPIC="/camera/color/image_fast_livo"
CAMERA_OUTPUT_TOPIC="/camera/color/image_fast_livo_foxglove"
CLOCK_HELPER="${SCRIPT_DIR}/ensure_clock.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Start and validate MID-70, D435i and FAST-LIVO, then configure a camera-only,
low-latency Foxglove Bridge.

Options:
  --check-seconds N   Sensor validation duration (default: ${CHECK_SECONDS})
  --camera-rate HZ    Foxglove raw-image rate (default: ${CAMERA_RATE})
  --port PORT         Foxglove WebSocket port (default: ${FOXGLOVE_PORT})
  -h, --help          Show this help

Environment overrides:
  DAIB_COMPOSE_FILE, DAIB_ENV_FILE, FOXGLOVE_CAMERA_RATE,
  FOXGLOVE_PORT, FOXGLOVE_SEND_BUFFER_LIMIT
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
    --camera-rate)
      (($# >= 2)) || fail "--camera-rate requires a value"
      CAMERA_RATE="$2"
      shift 2
      ;;
    --port)
      (($# >= 2)) || fail "--port requires a value"
      FOXGLOVE_PORT="$2"
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
[[ "$CAMERA_RATE" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || fail "--camera-rate must be a positive number"
awk -v rate="$CAMERA_RATE" 'BEGIN { exit !(rate > 0 && rate <= 10) }' \
  || fail "--camera-rate must be greater than 0 and at most 10"
[[ "$FOXGLOVE_PORT" =~ ^[0-9]+$ ]] \
  || fail "--port must be an integer"
(( FOXGLOVE_PORT >= 1 && FOXGLOVE_PORT <= 65535 )) \
  || fail "--port must be between 1 and 65535"
[[ "$SEND_BUFFER_LIMIT" =~ ^[0-9]+$ ]] \
  || fail "FOXGLOVE_SEND_BUFFER_LIMIT must be an integer"
(( SEND_BUFFER_LIMIT >= 1000000 && SEND_BUFFER_LIMIT <= 100000000 )) \
  || fail "FOXGLOVE_SEND_BUFFER_LIMIT must be between 1000000 and 100000000"

command -v docker >/dev/null || fail "docker is not installed"
[[ -x "${SCRIPT_DIR}/start_lio_only.sh" ]] \
  || fail "LIO/LIVO startup script is not executable"
[[ -r "$COMPOSE_FILE" ]] || fail "compose file is not readable: ${COMPOSE_FILE}"
[[ -r "$ENV_FILE" ]] || fail "runtime environment file is not readable: ${ENV_FILE}"
[[ -r "$CLOCK_HELPER" ]] || fail "clock helper is not readable: ${CLOCK_HELPER}"

source "$CLOCK_HELPER"
ensure_clock || fail "system clock check failed"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
elif command -v docker-compose >/dev/null; then
  COMPOSE=(docker-compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
else
  fail "Docker Compose is not installed"
fi

LOCK_DIR=/tmp/daib-start-flight-stack.lock
mkdir "$LOCK_DIR" 2>/dev/null \
  || fail "another flight-stack startup is already running"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

echo "[1/4] Starting and validating sensors and FAST-LIVO"
DAIB_COMPOSE_FILE="$COMPOSE_FILE" \
DAIB_ENV_FILE="$ENV_FILE" \
LIO_ENABLE_FOXGLOVE=false \
  "${SCRIPT_DIR}/start_lio_only.sh" --with-camera --check-seconds "$CHECK_SECONDS"

algorithm_id="$("${COMPOSE[@]}" ps -q algorithm)"
[[ -n "$algorithm_id" ]] || fail "algorithm container was not created"
[[ "$(docker inspect -f '{{.State.Status}}' "$algorithm_id")" == "running" ]] \
  || fail "algorithm container is not running"

echo "[2/4] Replacing the default Foxglove Bridge"
docker exec "$algorithm_id" bash -lc '
  pkill -INT -f "/opt/ros/noetic/bin/roslaunch --screen [f]oxglove_bridge foxglove_bridge.launch" 2>/dev/null || true
  pkill -TERM -f "/opt/ros/noetic/lib/topic_tools/[t]hrottle messages /camera/color/image_fast_livo .* /camera/color/image_fast_livo_foxglove" 2>/dev/null || true
  for _ in $(seq 1 20); do
    ss -lnt | grep -q ":'"$FOXGLOVE_PORT"' " || break
    sleep 0.25
  done
  if ss -lnt | grep -q ":'"$FOXGLOVE_PORT"' "; then
    pkill -TERM -f "/opt/ros/noetic/lib/nodelet/[n]odelet manager __name:=foxglove_nodelet_manager" 2>/dev/null || true
  fi
'

echo "[3/4] Starting ${CAMERA_RATE} Hz low-latency camera streaming"
docker exec -d "$algorithm_id" bash -lc \
  "source /opt/ros/noetic/setup.bash; \
   exec /opt/ros/noetic/lib/topic_tools/throttle messages \
     '${CAMERA_SOURCE_TOPIC}' '${CAMERA_RATE}' '${CAMERA_OUTPUT_TOPIC}' \
     >/tmp/image-fast-livo-throttle.log 2>&1"

docker exec -d "$algorithm_id" bash -lc \
  "source /opt/ros/noetic/setup.bash; \
   source /opt/foxglove_ws/devel/setup.bash --extend; \
   exec /opt/ros/noetic/bin/roslaunch --screen \
     foxglove_bridge foxglove_bridge.launch \
     port:='${FOXGLOVE_PORT}' \
     topic_whitelist:='[${CAMERA_OUTPUT_TOPIC}]' \
     service_whitelist:='[]' \
     capabilities:='[connectionGraph]' \
     send_buffer_limit:='${SEND_BUFFER_LIMIT}' \
     >/tmp/foxglove-bridge.log 2>&1"

echo "[4/4] Verifying Foxglove camera streaming"
ready=false
for _ in $(seq 1 40); do
  if docker exec "$algorithm_id" bash -lc \
      "source /opt/ros/noetic/setup.bash; \
       ss -lnt | grep -q ':${FOXGLOVE_PORT} '; \
       rostopic info '${CAMERA_OUTPUT_TOPIC}' 2>/dev/null | grep -q '/image_fast_livo_throttle_'; \
       [[ \"\$(rosparam get /foxglove_bridge/send_buffer_limit 2>/dev/null)\" == '${SEND_BUFFER_LIMIT}' ]]"; then
    ready=true
    break
  fi
  sleep 0.5
done

[[ "$ready" == "true" ]] || {
  docker exec "$algorithm_id" bash -lc \
    'tail -n 100 /tmp/image-fast-livo-throttle.log 2>/dev/null || true; tail -n 100 /tmp/foxglove-bridge.log 2>/dev/null || true' >&2
  fail "Foxglove camera stream did not become ready"
}

wifi_ip="$(ip -4 -o addr show dev wlan0 2>/dev/null | awk '{split($4, addr, "/"); print addr[1]; exit}')"
[[ -n "$wifi_ip" ]] || wifi_ip="<orange-pi-ip>"

echo
echo "[PASS] Flight stack is ready"
echo "  Foxglove: ws://${wifi_ip}:${FOXGLOVE_PORT}"
echo "  image:    ${CAMERA_OUTPUT_TOPIC} (${CAMERA_RATE} Hz target)"
echo "  buffer:   ${SEND_BUFFER_LIMIT} bytes"
echo "  mode:     camera-only, low-latency"
