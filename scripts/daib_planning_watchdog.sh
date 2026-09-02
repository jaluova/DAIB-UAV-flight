#!/usr/bin/env bash
set -Eeuo pipefail

# Observation-only recovery loop. It deliberately never restarts drivers,
# FAST-LIVO or the ROS master.
CONTAINER_ID="${1:?algorithm container id is required}"
MODE="${2:-live}"
USE_SIM_TIME="${3:-false}"
GOAL_STALL_TIMEOUT_S="${4:-8.0}"
MAX_VEL="${5:-0.5}"
MAX_ACC="${6:-1.0}"
ISOLATED_COMMAND_TOPIC="${7:-/daib_observe/position_cmd_unconnected}"
CLOUD_TIMEOUT_S="${8:-3.0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REFRESH_SCRIPT="${SCRIPT_DIR}/refresh_daib_goal.py"
STATE_FILE="/tmp/daib-planning-watchdog.state"
INTERVAL_S="${DAIB_WATCHDOG_INTERVAL_S:-2}"
EGO_GRACE_S="${DAIB_WATCHDOG_EGO_GRACE_S:-12}"
EXPLORER_GRACE_S="${DAIB_WATCHDOG_EXPLORER_GRACE_S:-10}"
FULL_GRACE_S="${DAIB_WATCHDOG_FULL_GRACE_S:-18}"
BAG_MISSING_LIMIT="${DAIB_WATCHDOG_BAG_MISSING_LIMIT:-3}"
EXPLORER_STALL_LIMIT="${DAIB_WATCHDOG_EXPLORER_STALL_LIMIT:-3}"

ROS_ENV='source /opt/ros/noetic/setup.bash; source /opt/daib_ws/devel/setup.bash; export ROS_MASTER_URI=http://127.0.0.1:11311; export ROS_HOSTNAME=127.0.0.1; unset ROS_IP'
EGO_LOG=/tmp/daib-ego-observe.log
EXPLORER_LOG=/tmp/daib-explorer.log

log() { printf '[WATCHDOG] %s\n' "$*"; }
container() { docker exec "$CONTAINER_ID" bash -lc "$ROS_ENV; $1"; }

rm -f "$STATE_FILE"
trap 'rm -f "$STATE_FILE"' EXIT

launch_explorer() {
  container "rosparam set /use_sim_time $USE_SIM_TIME; nohup roslaunch --screen daib_explorer explorer.launch use_sim_time:=$USE_SIM_TIME exploration_memory_restore:=true goal_stall_timeout_s:=$GOAL_STALL_TIMEOUT_S >$EXPLORER_LOG 2>&1 &"
}

launch_ego() {
  container "nohup roslaunch --screen ego_planner daib_single_uav.launch use_sim_time:=$USE_SIM_TIME max_vel:=$MAX_VEL max_acc:=$MAX_ACC cloud_timeout:=$CLOUD_TIMEOUT_S position_cmd_topic:=$ISOLATED_COMMAND_TOPIC >$EGO_LOG 2>&1 &"
}

refresh_goal() {
  docker cp "$REFRESH_SCRIPT" "$CONTAINER_ID:/tmp/refresh_daib_goal.py" >/dev/null
  docker exec "$CONTAINER_ID" bash -lc "$ROS_ENV; python3 /tmp/refresh_daib_goal.py" \
    >/tmp/daib-goal-refresh.log 2>&1 || log "goal refresh did not find a latched goal"
}

stop_ego() {
  container "rosnode kill /daib_ego_bridge /drone_0_ego_planner_node /drone_0_traj_server 2>/dev/null || true; pkill -TERM -f '[r]oslaunch --screen ego_planner daib_single_uav.launch' 2>/dev/null || true; : >$EGO_LOG"
}

stop_explorer() {
  container "rosnode kill /daib_explorer 2>/dev/null || true; pkill -TERM -f '[r]oslaunch --screen daib_explorer explorer.launch' 2>/dev/null || true; : >$EXPLORER_LOG"
}

stop_planning() {
  container "rosnode kill /daib_explorer /daib_ego_bridge /drone_0_ego_planner_node /drone_0_traj_server 2>/dev/null || true; pkill -TERM -f '[r]oslaunch --screen daib_explorer explorer.launch' 2>/dev/null || true; pkill -TERM -f '[r]oslaunch --screen ego_planner daib_single_uav.launch' 2>/dev/null || true; : >$EXPLORER_LOG; : >$EGO_LOG"
}

read_counts() {
  docker exec "$CONTAINER_ID" bash -lc '
    source /opt/ros/noetic/setup.bash
    source /opt/daib_ws/devel/setup.bash
    export ROS_MASTER_URI=http://127.0.0.1:11311
    export ROS_HOSTNAME=127.0.0.1
    unset ROS_IP
    for f in /tmp/daib-explorer.log /tmp/daib-ego-observe.log; do
      [[ -f "$f" ]] || : > "$f"
    done
    printf "EXPLORER_MAP=%s\n" "$(grep -Fc "[ DAIB Explorer ] map=" /tmp/daib-explorer.log 2>/dev/null || true)"
    printf "EXPLORER_WAIT=%s\n" "$(grep -Fc "waiting for fresh odometry and cloud" /tmp/daib-explorer.log 2>/dev/null || true)"
    printf "EGO_DEPTH=%s\n" "$(grep -Fc "Depth Lost! EMERGENCY_STOP" /tmp/daib-ego-observe.log 2>/dev/null || true)"
    printf "EGO_ASTAR=%s\n" "$(grep -Ec "a star error|Ran out of pool|Unable to handle the initial or end point" /tmp/daib-ego-observe.log 2>/dev/null || true)"
    printf "EGO_PLAN0=%s\n" "$(grep -Fc "plan_success=0" /tmp/daib-ego-observe.log 2>/dev/null || true)"
    printf "EGO_PLAN1=%s\n" "$(grep -Fc "plan_success=1" /tmp/daib-ego-observe.log 2>/dev/null || true)"
    printf "EGO_LAST=%s\n" "$(grep -E "plan_success=[01]" /tmp/daib-ego-observe.log 2>/dev/null | tail -n 1 || true)"
    printf "EGO_NODES=%s\n" "$(rosnode list 2>/dev/null | grep -Ec "^/(daib_ego_bridge|drone_0_ego_planner_node|drone_0_traj_server)$" || true)"
    printf "EXPLORER_NODE=%s\n" "$(rosnode list 2>/dev/null | grep -Fc /daib_explorer || true)"
  '
}

declare -A previous=()
bag_seen=false
bag_missing=0
explorer_stall_checks=0
while true; do
  [[ -f "$STATE_FILE" ]] || : > "$STATE_FILE"
  if [[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER_ID" 2>/dev/null || true)" != "running" ]]; then
    log "FAIL algorithm container stopped; keep manual control and return"
    exit 2
  fi
  if [[ "$MODE" == "bag" ]]; then
    if docker top "$CONTAINER_ID" -eo pid,args 2>/dev/null | grep -F 'rosbag play' >/dev/null; then
      bag_seen=true
      bag_missing=0
    else
      ((bag_missing += 1))
      if [[ "$bag_seen" == "true" ]] && ((bag_missing >= BAG_MISSING_LIMIT)); then
        log "bag playback finished; watchdog exits normally"
        exit 0
      fi
      sleep "$INTERVAL_S"
      continue
    fi
  fi

  state="$(read_counts 2>/dev/null || true)"
  declare -A current=()
  while IFS='=' read -r key value; do current["$key"]="$value"; done <<< "$state"
  [[ -n "${current[EXPLORER_MAP]:-}" ]] || { sleep "$INTERVAL_S"; continue; }

  if ((${#previous[@]} == 0)); then
    previous=([EXPLORER_MAP]="${current[EXPLORER_MAP]}" [EXPLORER_WAIT]="${current[EXPLORER_WAIT]}" [EGO_DEPTH]="${current[EGO_DEPTH]}" [EGO_ASTAR]="${current[EGO_ASTAR]}" [EGO_PLAN0]="${current[EGO_PLAN0]}" [EGO_PLAN1]="${current[EGO_PLAN1]}")
    log "monitor active: Explorer map=${current[EXPLORER_MAP]}, EGO nodes=${current[EGO_NODES]:-0}"
    sleep "$INTERVAL_S"
    continue
  fi

  map_delta=$((${current[EXPLORER_MAP]:-0} - ${previous[EXPLORER_MAP]:-0}))
  depth_delta=$((${current[EGO_DEPTH]:-0} - ${previous[EGO_DEPTH]:-0}))
  astar_delta=$((${current[EGO_ASTAR]:-0} - ${previous[EGO_ASTAR]:-0}))
  plan0_delta=$((${current[EGO_PLAN0]:-0} - ${previous[EGO_PLAN0]:-0}))
  previous=([EXPLORER_MAP]="${current[EXPLORER_MAP]}" [EXPLORER_WAIT]="${current[EXPLORER_WAIT]}" [EGO_DEPTH]="${current[EGO_DEPTH]}" [EGO_ASTAR]="${current[EGO_ASTAR]}" [EGO_PLAN0]="${current[EGO_PLAN0]}" [EGO_PLAN1]="${current[EGO_PLAN1]}")

  if ((${current[EGO_NODES]:-0} < 3 || ${current[EXPLORER_NODE]:-0} < 1)); then
    log "node health degraded: Explorer=${current[EXPLORER_NODE]:-0}, EGO=${current[EGO_NODES]:-0}"
  fi

  explorer_fault=false
  ego_fault=false
  if ((map_delta > 0)); then
    explorer_stall_checks=0
  else
    ((explorer_stall_checks += 1))
  fi
  if ((${current[EXPLORER_NODE]:-0} < 1 || explorer_stall_checks >= EXPLORER_STALL_LIMIT)); then
    explorer_fault=true
  fi
  # A* and plan_success=0 can both be normal while a frontier is temporarily
  # unreachable inside EGO's local horizon. Explorer's goal-stall policy owns
  # that case. Restart EGO only when its nodes disappear or its independent
  # planning cloud explicitly times out.
  if ((${current[EGO_NODES]:-0} < 3 || depth_delta > 0)); then
    ego_fault=true
  fi

  if [[ "${recovery:-}" == "" ]]; then
    if [[ "$explorer_fault" == "true" ]]; then
      recovery=explorer
      restart_ego_after_explorer="$ego_fault"
      if [[ "$ego_fault" == "true" ]]; then
        log "Explorer and EGO faults detected after ${explorer_stall_checks} stalled checks; restarting Explorer first"
      else
        log "Explorer fault detected after ${explorer_stall_checks} stalled checks; restarting Explorer only"
      fi
      stop_explorer || true
      sleep 1
      launch_explorer || true
      explorer_stall_checks=0
      recovery_started=$SECONDS
    elif [[ "$ego_fault" == "true" ]]; then
      recovery=ego
      log "EGO fault detected (depth +${depth_delta}, A* +${astar_delta}, plan0 +${plan0_delta}); restarting EGO only"
      stop_ego || true
      sleep 1
      launch_ego || true
      sleep 3
      refresh_goal || true
      recovery_started=$SECONDS
    fi
  elif [[ "${recovery:-}" == "explorer" ]] && ((SECONDS - recovery_started >= EXPLORER_GRACE_S)); then
    if ((${current[EXPLORER_NODE]:-0} >= 1 && ${current[EXPLORER_MAP]:-0} > 0)); then
      if [[ "${restart_ego_after_explorer:-false}" == "true" || $depth_delta -gt 0 || ${current[EGO_NODES]:-0} -lt 3 ]]; then
        recovery=ego
        log "Explorer recovered; restarting EGO and refreshing current goal"
        stop_ego || true
        sleep 1
        launch_ego || true
        sleep 3
        refresh_goal || true
        recovery_started=$SECONDS
      else
        log "Explorer-only recovery succeeded"
        explorer_stall_checks=0
        recovery=""
      fi
    else
      recovery=full
      log "Explorer-only recovery failed after ${EXPLORER_GRACE_S}s; restarting Explorer + EGO"
      stop_planning || true
      sleep 1
      launch_explorer || true
      explorer_stall_checks=0
      sleep 1
      launch_ego || true
      sleep 3
      refresh_goal || true
      recovery_started=$SECONDS
    fi
  elif [[ "${recovery:-}" == "ego" ]] && ((SECONDS - recovery_started >= EGO_GRACE_S)); then
    if ((${current[EGO_NODES]:-0} >= 3 &&
         ${current[EGO_DEPTH]:-0} == 0 &&
         ${current[EGO_PLAN0]:-0} + ${current[EGO_PLAN1]:-0} > 0)); then
      log "EGO recovered; returning to monitor mode"
      recovery=""
    else
      recovery=full
      log "EGO recovery failed after ${EGO_GRACE_S}s; restarting Explorer + EGO"
      stop_planning || true
      sleep 1
      launch_explorer || true
      explorer_stall_checks=0
      sleep 1
      launch_ego || true
      sleep 3
      refresh_goal || true
      recovery_started=$SECONDS
    fi
  elif [[ "${recovery:-}" == "full" ]] && ((SECONDS - recovery_started >= FULL_GRACE_S)); then
    if ((${current[EGO_NODES]:-0} >= 3 &&
         ${current[EXPLORER_NODE]:-0} >= 1 &&
         ${current[EXPLORER_MAP]:-0} > 0 &&
         ${current[EGO_DEPTH]:-0} == 0 &&
         ${current[EGO_PLAN0]:-0} + ${current[EGO_PLAN1]:-0} > 0)); then
      log "full planning restart recovered"
      recovery=""
    else
      log "FAIL planning recovery failed; keep manual control and return"
      exit 2
    fi
  fi

  sleep "$INTERVAL_S"
done
