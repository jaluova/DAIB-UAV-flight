#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/ros/noetic/setup.bash
source /opt/drivers_ws/devel/setup.bash

children=()
shutdown() {
  if ((${#children[@]})); then
    kill -TERM "${children[@]}" 2>/dev/null || true
    wait "${children[@]}" 2>/dev/null || true
  fi
}
trap shutdown EXIT INT TERM

for _ in $(seq 1 60); do
  if rosparam list >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
rosparam list >/dev/null 2>&1 || {
  echo "ROS master is not reachable at ${ROS_MASTER_URI}" >&2
  exit 1
}

if [[ "${CONFIGURE_LIDAR_INTERFACE:-false}" == "true" ]]; then
  : "${LIDAR_INTERFACE:?set LIDAR_INTERFACE to the Orange Pi 5 Max Ethernet interface}"
  : "${LIDAR_HOST_CIDR:?set LIDAR_HOST_CIDR, for example 192.168.1.100/24}"
  ip link set "${LIDAR_INTERFACE}" up
  ip addr replace "${LIDAR_HOST_CIDR}" dev "${LIDAR_INTERFACE}"
fi

if [[ "${ENABLE_REALSENSE:-true}" == "true" ]]; then
  read -r -a realsense_args <<< "${REALSENSE_ARGS:-enable_depth:=true enable_color:=true enable_gyro:=true enable_accel:=true unite_imu_method:=linear_interpolation}"
  roslaunch realsense2_camera rs_camera.launch "${realsense_args[@]}" &
  children+=("$!")
fi

if [[ "${ENABLE_LIVOX:-true}" == "true" ]]; then
  read -r -a livox_args <<< "${LIVOX_ARGS:-publish_freq:=10.0}"
  roslaunch livox_ros_driver livox_lidar_msg.launch "${livox_args[@]}" &
  children+=("$!")
fi

((${#children[@]})) || {
  echo "Both drivers are disabled; nothing to run" >&2
  exit 1
}

wait -n "${children[@]}"
