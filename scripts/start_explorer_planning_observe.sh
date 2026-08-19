#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${DAIB_COMPOSE_FILE:-${REPO_ROOT}/deploy/compose.orange-pi-5-max.yml}"
LIO_OVERRIDE_FILE="${DAIB_LIO_COMPOSE_FILE:-${REPO_ROOT}/deploy/compose.lio-only.yml}"
ENV_FILE="${DAIB_ENV_FILE:-${REPO_ROOT}/deploy/.env}"
CHECK_SECONDS="${CHECK_SECONDS:-15}"
CAMERA_RATE="${FOXGLOVE_CAMERA_RATE:-8.0}"
FOXGLOVE_PORT="${FOXGLOVE_PORT:-8765}"
SEND_BUFFER_LIMIT="${FOXGLOVE_SEND_BUFFER_LIMIT:-16000000}"
MAX_VEL="${EGO_OBSERVE_MAX_VEL:-0.5}"
MAX_ACC="${EGO_OBSERVE_MAX_ACC:-1.0}"
RESTART_DRIVERS=false
CAMERA_SOURCE_TOPIC="/camera/color/image_fast_livo"
CAMERA_OUTPUT_TOPIC="/camera/color/image_fast_livo_foxglove"
ISOLATED_COMMAND_TOPIC="/daib_observe/position_cmd_unconnected"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Start normal LIVO, DAIB-Explorer and EGO-Planner for observation only.
The EGO PositionCommand output is isolated from PX4/MAVROS/SDK control topics.

Options:
  --check-seconds N   Sensor validation duration (default: ${CHECK_SECONDS})
  --camera-rate HZ    Foxglove camera preview rate, 0 disables it (default: ${CAMERA_RATE})
  --max-vel MPS       Planning-only velocity limit (default: ${MAX_VEL})
  --max-acc MPS2      Planning-only acceleration limit (default: ${MAX_ACC})
  --port PORT         Foxglove WebSocket port (default: ${FOXGLOVE_PORT})
  --restart-drivers   Intentionally recreate the sensor driver container
  -h, --help          Show this help

This script does not start MAVROS, PX4 offboard, DJI SDK or a flight controller.
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
    --max-vel)
      (($# >= 2)) || fail "--max-vel requires a value"
      MAX_VEL="$2"
      shift 2
      ;;
    --max-acc)
      (($# >= 2)) || fail "--max-acc requires a value"
      MAX_ACC="$2"
      shift 2
      ;;
    --port)
      (($# >= 2)) || fail "--port requires a value"
      FOXGLOVE_PORT="$2"
      shift 2
      ;;
    --restart-drivers)
      RESTART_DRIVERS=true
      shift
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
for value_name in CAMERA_RATE MAX_VEL MAX_ACC; do
  value="${!value_name}"
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || fail "${value_name} must be a non-negative number"
done
awk -v rate="$CAMERA_RATE" 'BEGIN { exit !(rate >= 0 && rate <= 10) }' \
  || fail "--camera-rate must be between 0 and 10"
awk -v value="$MAX_VEL" 'BEGIN { exit !(value > 0 && value <= 2) }' \
  || fail "--max-vel must be greater than 0 and at most 2"
awk -v value="$MAX_ACC" 'BEGIN { exit !(value > 0 && value <= 3) }' \
  || fail "--max-acc must be greater than 0 and at most 3"
[[ "$FOXGLOVE_PORT" =~ ^[0-9]+$ ]] \
  || fail "--port must be an integer"
(( FOXGLOVE_PORT >= 1 && FOXGLOVE_PORT <= 65535 )) \
  || fail "--port must be between 1 and 65535"
[[ "$SEND_BUFFER_LIMIT" =~ ^[0-9]+$ ]] \
  || fail "FOXGLOVE_SEND_BUFFER_LIMIT must be an integer"
(( SEND_BUFFER_LIMIT >= 1000000 && SEND_BUFFER_LIMIT <= 100000000 )) \
  || fail "FOXGLOVE_SEND_BUFFER_LIMIT must be between 1000000 and 100000000"

[[ "$(uname -s)" == "Linux" ]] \
  || fail "this script must run on the Orange Pi Linux host"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) fail "expected an ARM64 host, found $(uname -m)" ;;
esac

command -v docker >/dev/null || fail "docker is not installed"
docker info >/dev/null 2>&1 || fail "the Docker daemon is not reachable"
[[ -x "${SCRIPT_DIR}/start_livo.sh" ]] \
  || fail "normal LIVO startup script is not executable"
[[ -r "$COMPOSE_FILE" ]] || fail "compose file is not readable: ${COMPOSE_FILE}"
[[ -r "$LIO_OVERRIDE_FILE" ]] \
  || fail "LIO override file is not readable: ${LIO_OVERRIDE_FILE}"
[[ -r "$ENV_FILE" ]] || fail "runtime environment file is not readable: ${ENV_FILE}"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$LIO_OVERRIDE_FILE")
elif command -v docker-compose >/dev/null; then
  COMPOSE=(docker-compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$LIO_OVERRIDE_FILE")
else
  fail "Docker Compose is not installed"
fi

LOCK_DIR=/tmp/daib-start-explorer-planning-observe.lock
mkdir "$LOCK_DIR" 2>/dev/null \
  || fail "another Explorer/EGO observation startup is already running"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

lio_args=(--check-seconds "$CHECK_SECONDS")
[[ "$RESTART_DRIVERS" == "true" ]] && lio_args+=(--restart-drivers)

echo "[1/7] Starting and validating sensors and normal LIVO"
DAIB_COMPOSE_FILE="$COMPOSE_FILE" \
DAIB_LIO_COMPOSE_FILE="$LIO_OVERRIDE_FILE" \
DAIB_ENV_FILE="$ENV_FILE" \
LIO_ENABLE_FOXGLOVE=false \
  "${SCRIPT_DIR}/start_livo.sh" "${lio_args[@]}"

algorithm_id="$("${COMPOSE[@]}" ps -q algorithm)"
[[ -n "$algorithm_id" ]] || fail "algorithm container was not created"
[[ "$(docker inspect -f '{{.State.Status}}' "$algorithm_id")" == "running" ]] \
  || fail "algorithm container is not running"

ROS_ENV='source /opt/ros/noetic/setup.bash; source /opt/daib_ws/devel/setup.bash; export ROS_MASTER_URI=http://127.0.0.1:11311; export ROS_HOSTNAME=127.0.0.1; unset ROS_IP'

container_ros() {
  docker exec "$algorithm_id" bash -lc "$ROS_ENV; $1"
}

wait_for_node() {
  local node_name="$1"
  for _ in $(seq 1 40); do
    container_ros "rosnode list 2>/dev/null | grep -Fxq '$node_name'" && return 0
    sleep 0.5
  done
  return 1
}

echo "[2/7] Starting DAIB-Explorer"
docker exec -d "$algorithm_id" bash -lc \
  "$ROS_ENV; exec roslaunch --screen daib_explorer explorer.launch \
   >/tmp/daib-explorer.log 2>&1"
wait_for_node /daib_explorer || {
  container_ros 'tail -n 120 /tmp/daib-explorer.log 2>/dev/null || true' >&2
  fail "DAIB-Explorer node did not start"
}

echo "[3/7] Waiting for synchronized Explorer inputs"
explorer_ready=false
for _ in $(seq 1 40); do
  if container_ros \
      "timeout --foreground --kill-after=0.2 1.5 rostopic echo -n 1 /daib_explorer/ready 2>/dev/null | grep -Eiq 'data:[[:space:]]*true'"; then
    explorer_ready=true
    break
  fi
  sleep 0.5
done
[[ "$explorer_ready" == "true" ]] || {
  container_ros 'tail -n 160 /tmp/daib-explorer.log 2>/dev/null || true' >&2
  fail "Explorer did not report ready=true"
}

echo "[4/7] Starting EGO-Planner with an isolated command output"
docker exec -d "$algorithm_id" bash -lc \
  "$ROS_ENV; exec roslaunch --screen ego_planner daib_single_uav.launch \
     max_vel:='$MAX_VEL' \
     max_acc:='$MAX_ACC' \
     position_cmd_topic:='$ISOLATED_COMMAND_TOPIC' \
   >/tmp/daib-ego-observe.log 2>&1"

for node_name in /daib_ego_bridge /drone_0_ego_planner_node /drone_0_traj_server; do
  wait_for_node "$node_name" || {
    container_ros 'tail -n 180 /tmp/daib-ego-observe.log 2>/dev/null || true' >&2
    fail "EGO observation node did not start: ${node_name}"
  }
done

for _ in $(seq 1 20); do
  command_type="$(container_ros "rostopic type '$ISOLATED_COMMAND_TOPIC' 2>/dev/null" || true)"
  [[ "$command_type" == "quadrotor_msgs/PositionCommand" ]] && break
  sleep 0.25
done
[[ "${command_type:-}" == "quadrotor_msgs/PositionCommand" ]] \
  || fail "isolated EGO command topic was not advertised"
command_info="$(container_ros "rostopic info '$ISOLATED_COMMAND_TOPIC'")"
grep -Fq 'Subscribers: None' <<< "$command_info" || {
  printf '%s\n' "$command_info" >&2
  fail "isolated EGO command topic unexpectedly has a subscriber"
}

echo "[5/7] Starting the planning-observation Foxglove Bridge"
if awk -v rate="$CAMERA_RATE" 'BEGIN { exit !(rate > 0) }'; then
  docker exec -d "$algorithm_id" bash -lc \
    "source /opt/ros/noetic/setup.bash; \
     exec /opt/ros/noetic/lib/topic_tools/throttle messages \
       '$CAMERA_SOURCE_TOPIC' '$CAMERA_RATE' '$CAMERA_OUTPUT_TOPIC' \
       >/tmp/image-fast-livo-throttle.log 2>&1"
fi

TOPIC_WHITELIST='[/tf, /tf_static, /daib_slam/odom, /cloud_registered, /camera/color/image_fast_livo_foxglove, /daib_explorer/.*, /daib_ego/goal, /daib_ego/bridge_state, /daib_ego/accepted_generation, /drone_0_ego_planner_node/goal_point, /drone_0_ego_planner_node/optimal_list, /drone_0_ego_planner_node/grid_map/occupancy_inflate]'
docker exec -d "$algorithm_id" bash -lc \
  "source /opt/ros/noetic/setup.bash; \
   source /opt/foxglove_ws/devel/setup.bash --extend; \
   exec roslaunch --screen foxglove_bridge foxglove_bridge.launch \
     port:='$FOXGLOVE_PORT' \
     topic_whitelist:='$TOPIC_WHITELIST' \
     service_whitelist:='[]' \
     capabilities:='[connectionGraph]' \
     send_buffer_limit:='$SEND_BUFFER_LIMIT' \
     >/tmp/foxglove-bridge.log 2>&1"

echo "[6/7] Verifying Foxglove and planning topic contracts"
foxglove_ready=false
for _ in $(seq 1 40); do
  if container_ros \
      "ss -lnt | grep -q ':${FOXGLOVE_PORT} '; \
       [[ \"\$(rostopic type /daib_explorer/goal 2>/dev/null)\" == geometry_msgs/PoseStamped ]]; \
       [[ \"\$(rostopic type /daib_explorer/planning_cloud 2>/dev/null)\" == sensor_msgs/PointCloud2 ]]; \
       [[ \"\$(rostopic type /daib_ego/goal 2>/dev/null)\" == geometry_msgs/PoseStamped ]]"; then
    foxglove_ready=true
    break
  fi
  sleep 0.5
done
[[ "$foxglove_ready" == "true" ]] || {
  container_ros \
    'tail -n 120 /tmp/daib-explorer.log 2>/dev/null || true; tail -n 160 /tmp/daib-ego-observe.log 2>/dev/null || true; tail -n 120 /tmp/foxglove-bridge.log 2>/dev/null || true' >&2
  fail "planning observation topics or Foxglove did not become ready"
}

echo "[7/7] Confirming that no flight-control subscriber is connected"
command_info="$(container_ros "rostopic info '$ISOLATED_COMMAND_TOPIC'")"
grep -Fq 'Subscribers: None' <<< "$command_info" || {
  printf '%s\n' "$command_info" >&2
  fail "do not fly: the isolated planning command acquired a subscriber"
}

wifi_ip="$(ip -4 -o addr show dev wlan0 2>/dev/null | awk '{split($4, addr, "/"); print addr[1]; exit}')"
[[ -n "$wifi_ip" ]] || wifi_ip="<orange-pi-ip>"

echo
echo "[PASS] Explorer + EGO planning observation is ready"
echo "  Foxglove: ws://${wifi_ip}:${FOXGLOVE_PORT}"
echo "  frame:    camera_init"
echo "  goal:     /daib_explorer/goal"
echo "  frontier: /daib_explorer/selected_cluster_frontiers"
echo "  route:    /drone_0_ego_planner_node/optimal_list"
echo "  obstacles: /daib_explorer/planning_cloud"
if awk -v rate="$CAMERA_RATE" 'BEGIN { exit !(rate > 0) }'; then
  echo "  image:    ${CAMERA_OUTPUT_TOPIC} (${CAMERA_RATE} Hz target)"
fi
echo "  command:  ${ISOLATED_COMMAND_TOPIC} (no subscribers)"
echo
echo "[SAFETY] Observation only: keep flying with the remote controller."
echo "[SAFETY] This script does not connect EGO output to PX4, MAVROS or an SDK."
