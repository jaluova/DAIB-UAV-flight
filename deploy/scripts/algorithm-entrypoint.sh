#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/ros/noetic/setup.bash
source /opt/daib_ws/devel/setup.bash
source /opt/foxglove_ws/devel/setup.bash --extend

children=()
shutdown() {
  if ((${#children[@]})); then
    kill -TERM "${children[@]}" 2>/dev/null || true
    wait "${children[@]}" 2>/dev/null || true
  fi
}
trap shutdown EXIT INT TERM

if [[ "${START_ROS_MASTER:-true}" == "true" ]]; then
  roscore &
  children+=("$!")
fi

for _ in $(seq 1 30); do
  if rosparam list >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
rosparam list >/dev/null 2>&1 || {
  echo "ROS master is not reachable at ${ROS_MASTER_URI}" >&2
  exit 1
}

if (($#)); then
  exec "$@"
fi

bag_file="${BAG_FILE:-}"
launch_spec="${ALGORITHM_LAUNCH:-fast_livo mapping_mid70_d435i.launch rviz:=false use_camera:=false}"
if [[ -n "$bag_file" ]]; then
  [[ -r "$bag_file" ]] || {
    echo "BAG_FILE is not readable: $bag_file" >&2
    exit 1
  }
  rosparam set /use_sim_time true
  launch_spec="${BAG_ALGORITHM_LAUNCH:-fast_livo mapping_mid70_d435i.launch rviz:=false use_camera:=true}"
else
  rosparam set /use_sim_time false
fi

read -r -a launch_args <<< "$launch_spec"
roslaunch "${launch_args[@]}" &
algorithm_pid=$!
children+=("$algorithm_pid")

if [[ "${ENABLE_FOXGLOVE:-true}" == "true" ]]; then
  roslaunch --screen foxglove_bridge foxglove_bridge.launch \
    "port:=${FOXGLOVE_PORT:-8765}" &
  children+=("$!")
fi

if [[ -n "$bag_file" ]]; then
  bag_args=(--clock "--rate=${BAG_RATE:-1.0}" "--delay=${BAG_DELAY:-2.0}")
  if [[ "${BAG_LOOP:-false}" == "true" ]]; then
    bag_args+=(--loop)
  fi
  rosbag play "${bag_args[@]}" "$bag_file" &
  children+=("$!")
fi

wait "$algorithm_pid"
