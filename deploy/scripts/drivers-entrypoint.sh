#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/ros/noetic/setup.bash
source /opt/drivers_ws/devel/setup.bash

fail() {
  echo "[drivers-entrypoint] $*" >&2
  exit 1
}

configure_lidar_network() {
  local interface="${LIDAR_INTERFACE:?set LIDAR_INTERFACE to the Orange Pi Ethernet interface}"
  local host_cidr="${LIDAR_HOST_CIDR:?set LIDAR_HOST_CIDR, for example 192.168.1.50/24}"
  local host_ip="${host_cidr%/*}"
  local device_ip="${LIDAR_DEVICE_IP:-192.168.1.119}"
  local route

  [[ "$interface" =~ ^[[:alnum:]_.:-]+$ ]] \
    || fail "invalid LIDAR_INTERFACE: ${interface}"
  [[ "$host_cidr" == */* ]] \
    || fail "LIDAR_HOST_CIDR must include a prefix length: ${host_cidr}"
  ip link show dev "$interface" >/dev/null 2>&1 \
    || fail "LiDAR interface does not exist: ${interface}"

  if [[ "${CONFIGURE_LIDAR_INTERFACE:-false}" == "true" ]]; then
    ip link set "$interface" up
    ip addr replace "$host_cidr" dev "$interface"
  fi

  if [[ "${CONFIGURE_LIDAR_RP_FILTER:-false}" == "true" ]]; then
    local rp_filter_path
    for rp_filter_path in \
      /proc/sys/net/ipv4/conf/all/rp_filter \
      "/proc/sys/net/ipv4/conf/${interface}/rp_filter"; do
      [[ -w "$rp_filter_path" ]] \
        || fail "cannot configure ${rp_filter_path}; host networking and privileged mode are required"
      printf '0\n' > "$rp_filter_path"
    done
  fi

  ip -4 addr show dev "$interface" | grep -Fq "inet ${host_cidr}" \
    || fail "${interface} does not have the required address ${host_cidr}"
  route="$(ip -4 route get "$device_ip" 2>&1)" \
    || fail "cannot resolve a route to LiDAR ${device_ip}"
  [[ " $route " == *" dev ${interface} "* ]] \
    || fail "route to ${device_ip} does not use ${interface}: ${route}"
  [[ " $route " == *" src ${host_ip} "* ]] \
    || fail "route to ${device_ip} does not use source ${host_ip}: ${route}"

  if [[ "${VERIFY_LIDAR_RP_FILTER:-true}" == "true" ]]; then
    [[ "$(< /proc/sys/net/ipv4/conf/all/rp_filter)" == "0" ]] \
      || fail "net.ipv4.conf.all.rp_filter must be 0 for Livox broadcast reception"
    [[ "$(< "/proc/sys/net/ipv4/conf/${interface}/rp_filter")" == "0" ]] \
      || fail "net.ipv4.conf.${interface}.rp_filter must be 0 for Livox broadcast reception"
  fi

  echo "[drivers-entrypoint] LiDAR network ready: ${interface} ${host_cidr} -> ${device_ip}"
}

children=()
shutdown() {
  if ((${#children[@]})); then
    kill -TERM "${children[@]}" 2>/dev/null || true
    wait "${children[@]}" 2>/dev/null || true
  fi
}
trap shutdown EXIT INT TERM

if [[ "${ENABLE_LIVOX:-true}" == "true" ]]; then
  configure_lidar_network
  if [[ "${LIDAR_NETWORK_PREFLIGHT_ONLY:-false}" == "true" ]]; then
    echo "[drivers-entrypoint] LiDAR network preflight passed"
    exit 0
  fi
fi

for _ in $(seq 1 60); do
  if rosparam list >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
rosparam list >/dev/null 2>&1 \
  || fail "ROS master is not reachable at ${ROS_MASTER_URI}"

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
