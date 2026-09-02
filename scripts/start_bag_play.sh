#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${DAIB_COMPOSE_FILE:-${REPO_ROOT}/deploy/compose.orange-pi-5-max.yml}"
LIO_OVERRIDE_FILE="${DAIB_LIO_COMPOSE_FILE:-${REPO_ROOT}/deploy/compose.lio-only.yml}"
ENV_FILE="${DAIB_ENV_FILE:-${REPO_ROOT}/deploy/.env}"
RATE=1.0
DELAY=8.0
BAG_PATH=""
BAG_FILES=()
EXPLORER_OBSERVE=false
ISOLATED_COMMAND_TOPIC="/daib_observe/position_cmd_unconnected"
EGO_MAX_VEL="${EGO_OBSERVE_MAX_VEL:-0.5}"
EGO_MAX_ACC="${EGO_OBSERVE_MAX_ACC:-1.0}"
EXPLORER_GOAL_STALL_TIMEOUT_S="${EXPLORER_GOAL_STALL_TIMEOUT_S:-8.0}"
EGO_CLOUD_TIMEOUT_S="${EGO_CLOUD_TIMEOUT_S:-3.0}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--rate RATE] [--delay SECONDS] [--explorer-observe] [BAG]

Replay one FAST-LIVO input bag session through the algorithm and the all-topic
Foxglove Bridge. BAG may be a host file or directory below BAGS_DIR, or a
/bags path. The newest recorded session and all of its split bags are selected
when BAG is omitted.

Options:
  --rate RATE       Playback rate (default: ${RATE})
  --delay SECONDS   Delay before playback starts (default: ${DELAY})
  --explorer-observe  Also start DAIB-Explorer and EGO-Planner in observation-only mode
  -h, --help        Show this help

With --explorer-observe, EGO PositionCommand is isolated at
${ISOLATED_COMMAND_TOPIC}; no PX4/MAVROS/SDK control process is started.
Explorer replaces a goal after ${EXPLORER_GOAL_STALL_TIMEOUT_S}s without progress;
override with EXPLORER_GOAL_STALL_TIMEOUT_S for a slower or faster platform.
EOF
}

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --rate)
      (($# >= 2)) || fail "--rate requires a value"
      RATE="$2"
      shift 2
      ;;
    --delay)
      (($# >= 2)) || fail "--delay requires a value"
      DELAY="$2"
      shift 2
      ;;
    --explorer-observe)
      EXPLORER_OBSERVE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$BAG_PATH" ]] || fail "only one BAG path may be specified"
      BAG_PATH="$1"
      shift
      ;;
  esac
done

[[ "$RATE" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "--rate must be numeric"
[[ "$DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "--delay must be numeric"
awk -v value="$RATE" 'BEGIN { exit !(value > 0 && value <= 4) }' \
  || fail "--rate must be greater than 0 and at most 4"
awk -v value="$DELAY" 'BEGIN { exit !(value >= 0 && value <= 60) }' \
  || fail "--delay must be between 0 and 60 seconds"
[[ "$EXPLORER_GOAL_STALL_TIMEOUT_S" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || fail "EXPLORER_GOAL_STALL_TIMEOUT_S must be numeric"
awk -v value="$EXPLORER_GOAL_STALL_TIMEOUT_S" 'BEGIN { exit !(value >= 1 && value <= 60) }' \
  || fail "EXPLORER_GOAL_STALL_TIMEOUT_S must be between 1 and 60 seconds"
[[ "$EGO_CLOUD_TIMEOUT_S" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || fail "EGO_CLOUD_TIMEOUT_S must be numeric"
awk -v value="$EGO_CLOUD_TIMEOUT_S" 'BEGIN { exit !(value >= 0.5 && value <= 10) }' \
  || fail "EGO_CLOUD_TIMEOUT_S must be between 0.5 and 10 seconds"

command -v docker >/dev/null || fail "docker is not installed"
[[ -r "$COMPOSE_FILE" ]] || fail "compose file is not readable: ${COMPOSE_FILE}"
[[ -r "$LIO_OVERRIDE_FILE" ]] || fail "LIO override is not readable: ${LIO_OVERRIDE_FILE}"
[[ -r "$ENV_FILE" ]] || fail "environment file is not readable: ${ENV_FILE}"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$LIO_OVERRIDE_FILE")
elif command -v docker-compose >/dev/null; then
  COMPOSE=(docker-compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$LIO_OVERRIDE_FILE")
else
  fail "Docker Compose is not installed"
fi

BAGS_ROOT="$(sed -n 's/^BAGS_DIR=//p' "$ENV_FILE" | tail -n 1)"
BAGS_ROOT="${BAGS_ROOT:-/mnt/ssd/bags}"
BAGS_ROOT="${BAGS_ROOT#\"}"
BAGS_ROOT="${BAGS_ROOT%\"}"
BAGS_ROOT="${BAGS_ROOT#\'}"
BAGS_ROOT="${BAGS_ROOT%\'}"
[[ -d "$BAGS_ROOT" ]] || fail "BAGS_DIR does not exist: ${BAGS_ROOT}"
BAGS_ROOT="$(realpath "$BAGS_ROOT")"

if [[ -z "$BAG_PATH" ]]; then
  latest_session="$(find "$BAGS_ROOT/fast_livo_real" -mindepth 1 -maxdepth 1 -type d \
    -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2-)"
  [[ -n "$latest_session" ]] \
    || fail "no recorded bag session found below ${BAGS_ROOT}/fast_livo_real"
  mapfile -t BAG_FILES < <(find "$latest_session" -maxdepth 1 -type f -name '*.bag' \
    -printf '%f\n' | sort -V | sed "s#^#${latest_session}/#")
  ((${#BAG_FILES[@]})) || fail "no bag files found in latest session: ${latest_session}"
elif [[ "$BAG_PATH" == /bags/* ]]; then
  BAG_PATH="${BAGS_ROOT}/${BAG_PATH#/bags/}"
elif [[ "$BAG_PATH" != /* ]]; then
  BAG_PATH="${PWD}/${BAG_PATH}"
fi

if [[ -n "$BAG_PATH" ]]; then
  [[ -e "$BAG_PATH" ]] || fail "bag path does not exist: ${BAG_PATH}"
  BAG_PATH="$(realpath "$BAG_PATH")"
  if [[ -d "$BAG_PATH" ]]; then
    mapfile -t BAG_FILES < <(find "$BAG_PATH" -maxdepth 1 -type f -name '*.bag' \
      -printf '%f\n' | sort -V | sed "s#^#${BAG_PATH}/#")
    ((${#BAG_FILES[@]})) || fail "no bag files found in directory: ${BAG_PATH}"
  else
    BAG_FILES=("$BAG_PATH")
  fi
fi

for bag_file in "${BAG_FILES[@]}"; do
  bag_file="$(realpath "$bag_file")"
  [[ -f "$bag_file" ]] || fail "bag does not exist: ${bag_file}"
  [[ "$bag_file" == "$BAGS_ROOT"/* ]] \
    || fail "bag must be below BAGS_DIR (${BAGS_ROOT})"
done
CONTAINER_BAG_FILES=""
for bag_file in "${BAG_FILES[@]}"; do
  container_bag="/bags/${bag_file#${BAGS_ROOT}/}"
  CONTAINER_BAG_FILES+="${CONTAINER_BAG_FILES:+ }${container_bag}"
done

LOCK_DIR=/tmp/daib-start-bag-play.lock
mkdir "$LOCK_DIR" 2>/dev/null || fail "another bag playback startup is running"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

echo "[1/5] Starting the persistent ROS Master"
"${COMPOSE[@]}" up -d --no-build --no-deps roscore >/dev/null

echo "[2/5] Stopping live sensor and algorithm services"
"${COMPOSE[@]}" stop drivers algorithm >/dev/null
"${COMPOSE[@]}" exec -T roscore bash -lc \
  'source /opt/ros/noetic/setup.bash; printf "y\n" | rosnode cleanup >/dev/null 2>&1 || true'

echo "[3/5] Starting FAST-LIVO bag playback"
BAG_FILES="$CONTAINER_BAG_FILES" \
BAG_RATE="$RATE" \
BAG_DELAY="$DELAY" \
BAG_LOOP=false \
LIO_ENABLE_FOXGLOVE=true \
  "${COMPOSE[@]}" up -d --no-build --no-deps --force-recreate algorithm >/dev/null

algorithm_id="$("${COMPOSE[@]}" ps -q algorithm)"
[[ -n "$algorithm_id" ]] || fail "algorithm container was not created"

if [[ "$EXPLORER_OBSERVE" == "true" ]]; then
  docker cp "${REPO_ROOT}/src/DAIB-Planner/src/planner/plan_manage/launch/daib_single_uav.launch" \
    "$algorithm_id:/opt/daib_ws/src/ego_planner_packages/plan_manage/launch/daib_single_uav.launch"
  chmod +x "${SCRIPT_DIR}/daib_planning_watchdog.sh"
  [[ -r "${SCRIPT_DIR}/refresh_daib_goal.py" ]] || fail "goal refresh helper is missing"
  pkill -TERM -f '[d]aib_planning_watchdog.sh' 2>/dev/null || true
fi

echo "[4/5] Waiting for rosbag and Foxglove"
ready=false
for _ in $(seq 1 60); do
  if docker top "$algorithm_id" -eo pid,args 2>/dev/null | grep -F "rosbag play" >/dev/null &&
      ss -lnt | grep -q ':8765 '; then
    ready=true
    break
  fi
  sleep 0.5
done
[[ "$ready" == "true" ]] || {
  "${COMPOSE[@]}" logs --tail 120 algorithm >&2 || true
  fail "bag playback or Foxglove did not become ready"
}

if [[ "$EXPLORER_OBSERVE" == "true" ]]; then
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

  echo "[5/7] Starting DAIB-Explorer in bag/sim-time mode"
  docker exec -d "$algorithm_id" bash -lc \
    "$ROS_ENV; exec roslaunch --screen daib_explorer explorer.launch \
       use_sim_time:=true \
       goal_stall_timeout_s:='$EXPLORER_GOAL_STALL_TIMEOUT_S' \
       >/tmp/daib-explorer.log 2>&1"
  wait_for_node /daib_explorer || {
    container_ros 'tail -n 160 /tmp/daib-explorer.log 2>/dev/null || true' >&2
    fail "DAIB-Explorer node did not start during bag playback"
  }

  explorer_ready=false
  for _ in $(seq 1 40); do
    if docker exec "$algorithm_id" bash -lc \
        "grep -Fq '[ DAIB Explorer ] map=' /tmp/daib-explorer.log 2>/dev/null"; then
      explorer_ready=true
      break
    fi
    sleep 0.5
  done
  [[ "$explorer_ready" == "true" ]] || {
    container_ros 'tail -n 200 /tmp/daib-explorer.log 2>/dev/null || true' >&2
    fail "Explorer did not report ready=true during bag playback"
  }

  echo "[6/7] Starting EGO-Planner in observation-only mode"
  docker exec -d "$algorithm_id" bash -lc \
    "$ROS_ENV; exec roslaunch --screen ego_planner daib_single_uav.launch \
       use_sim_time:=true \
       max_vel:='$EGO_MAX_VEL' \
       max_acc:='$EGO_MAX_ACC' \
       cloud_timeout:='$EGO_CLOUD_TIMEOUT_S' \
       position_cmd_topic:='$ISOLATED_COMMAND_TOPIC' \
       >/tmp/daib-ego-observe.log 2>&1"

  for node_name in /daib_ego_bridge /drone_0_ego_planner_node /drone_0_traj_server; do
    wait_for_node "$node_name" || {
      container_ros 'tail -n 220 /tmp/daib-ego-observe.log 2>/dev/null || true' >&2
      fail "EGO observation node did not start during bag playback: ${node_name}"
    }
  done

  command_type=""
  for _ in $(seq 1 20); do
    command_type="$(container_ros "rostopic type '$ISOLATED_COMMAND_TOPIC' 2>/dev/null" || true)"
    [[ "$command_type" == "quadrotor_msgs/PositionCommand" ]] && break
    sleep 0.25
  done
  [[ "$command_type" == "quadrotor_msgs/PositionCommand" ]] \
    || fail "isolated EGO command topic was not advertised"
  command_info="$(container_ros "rostopic info '$ISOLATED_COMMAND_TOPIC'")"
  grep -Fq 'Subscribers: None' <<< "$command_info" || {
    printf '%s\n' "$command_info" >&2
    fail "isolated EGO command topic unexpectedly has a subscriber"
  }

  echo "[7/7] Starting planning recovery watchdog"
  nohup "${SCRIPT_DIR}/daib_planning_watchdog.sh" \
    "$algorithm_id" bag true "$EXPLORER_GOAL_STALL_TIMEOUT_S" "$EGO_MAX_VEL" "$EGO_MAX_ACC" "$ISOLATED_COMMAND_TOPIC" \
    "$EGO_CLOUD_TIMEOUT_S" \
    >/tmp/daib-planning-watchdog.log 2>&1 &
fi

wifi_ip="$(ip -4 -o addr show dev wlan0 2>/dev/null | awk '{split($4, addr, "/"); print addr[1]; exit}')"
[[ -n "$wifi_ip" ]] || wifi_ip="<orange-pi-ip>"

if [[ "$EXPLORER_OBSERVE" == "true" ]]; then
  echo "[7/7] Playback + Explorer/EGO observation ready"
else
  echo "[5/5] Playback ready"
fi
echo "  bags:"
for bag_file in "${BAG_FILES[@]}"; do
  echo "    ${bag_file}"
done
echo "  rate:       ${RATE}x"
echo "  start delay:${DELAY}s"
echo "  Foxglove:   ws://${wifi_ip}:8765"
echo "  fixed frame: camera_init"
if [[ "$EXPLORER_OBSERVE" == "true" ]]; then
  echo "  Explorer goal: /daib_explorer/goal"
  echo "  EGO route:     /drone_0_ego_planner_node/optimal_list"
  echo "  obstacle cloud:/daib_explorer/planning_cloud"
  echo "  command:       ${ISOLATED_COMMAND_TOPIC} (no subscribers)"
  echo
  echo "[SAFETY] Bag observation only; no PX4, MAVROS, SDK or flight controller is started."
fi
echo
echo "Return to live sensors with:"
echo "  ./scripts/start_flight_stack.sh --check-seconds 15 --camera-rate 6"
