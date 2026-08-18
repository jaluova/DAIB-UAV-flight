#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${DAIB_COMPOSE_FILE:-${REPO_ROOT}/deploy/compose.orange-pi-5-max.yml}"
LIO_OVERRIDE_FILE="${DAIB_LIO_COMPOSE_FILE:-${REPO_ROOT}/deploy/compose.lio-only.yml}"
ENV_FILE="${DAIB_ENV_FILE:-${REPO_ROOT}/deploy/.env}"
CHECK_SECONDS="${CHECK_SECONDS:-8}"
REALSENSE_USB_ID="${REALSENSE_USB_ID:-8086:0b3a}"
CLOCK_HELPER="${SCRIPT_DIR}/ensure_clock.sh"
WITH_CAMERA=false
RESTART_DRIVERS=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check-seconds N] [--with-camera] [--restart-drivers]

Start a LIO-only Orange Pi stack:
  - FAST-LIVO with use_camera:=false
  - Livox MID-70
  - D435i gyroscope and accelerometer only
  - no color or depth image streams

Use --with-camera (or start_livo.sh) to run normal LIVO with the D435i image.
Healthy driver containers are reused by default; use --restart-drivers to force
a RealSense/Livox driver restart.
Set LIO_ENABLE_FOXGLOVE=false to disable the Foxglove Bridge.
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
    --with-camera)
      WITH_CAMERA=true
      shift
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
[[ -r "$LIO_OVERRIDE_FILE" ]] \
  || fail "LIO override file is not readable: ${LIO_OVERRIDE_FILE}"
[[ -r "$ENV_FILE" ]] || fail "runtime environment file is not readable: ${ENV_FILE}"
[[ -r "${REPO_ROOT}/src/DAIB-LIVO/config/mid70_d435i.yaml" ]] \
  || fail "calibration file is not readable"
[[ -r "${REPO_ROOT}/deploy/scripts/check_sensor_timing.py" ]] \
  || fail "LIO timing checker is not readable"
[[ -r "$CLOCK_HELPER" ]] || fail "clock helper is not readable: ${CLOCK_HELPER}"
lsusb -d "$REALSENSE_USB_ID" >/dev/null 2>&1 \
  || fail "D435i USB device ${REALSENSE_USB_ID} is not connected"

source "$CLOCK_HELPER"
ensure_clock || fail "system clock check failed"

if [[ "$WITH_CAMERA" == "true" ]]; then
  export DAIB_ALGORITHM_LAUNCH='fast_livo mapping_mid70_d435i.launch rviz:=false use_camera:=true'
  export DAIB_REALSENSE_ARGS='enable_depth:=true enable_color:=true enable_gyro:=true enable_accel:=true unite_imu_method:=linear_interpolation'
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$LIO_OVERRIDE_FILE")
elif command -v docker-compose >/dev/null; then
  COMPOSE=(docker-compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$LIO_OVERRIDE_FILE")
else
  fail "Docker Compose is not installed"
fi

LOCK_DIR=/tmp/daib-start-lio-only.lock
mkdir "$LOCK_DIR" 2>/dev/null \
  || fail "another LIO-only startup is already running"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

wait_for_state() {
  local container_id="$1"
  local service="$2"
  local wanted="$3"
  local state
  for _ in $(seq 1 60); do
    if [[ "$wanted" == "healthy" ]]; then
      state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
    else
      state="$(docker inspect -f '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
    fi
    [[ "$state" == "$wanted" ]] && return 0
    [[ "$state" == "exited" || "$state" == "dead" || "$state" == "unhealthy" ]] && break
    sleep 1
  done
  "${COMPOSE[@]}" logs --tail 120 "$service" >&2 || true
  fail "${service} did not become ${wanted}"
}

driver_network_ready() {
  local container_id="$1"
  local interface="$2"
  local host_cidr="$3"
  local device_ip="$4"
  docker exec "$container_id" bash -lc '
    set -Eeuo pipefail
    interface="$1"
    host_cidr="$2"
    device_ip="$3"
    host_ip="${host_cidr%/*}"
    ip -4 addr show dev "$interface" | grep -Fq "inet ${host_cidr}"
    route="$(ip -4 route get "$device_ip")"
    [[ " $route " == *" dev ${interface} "* ]]
    [[ " $route " == *" src ${host_ip} "* ]]
  ' -- "$interface" "$host_cidr" "$device_ip"
}

echo "[1/7] Validating LIO-only Compose configuration"
"${COMPOSE[@]}" config --quiet

echo "[2/7] Starting the persistent ROS Master"
"${COMPOSE[@]}" up -d --no-build --no-deps roscore
roscore_id="$("${COMPOSE[@]}" ps -q roscore)"
[[ -n "$roscore_id" ]] || fail "roscore container was not created"
wait_for_state "$roscore_id" roscore healthy

if [[ "$WITH_CAMERA" == "true" ]]; then
  echo "[3/7] Recreating the algorithm service in normal LIVO mode"
else
  echo "[3/7] Recreating the algorithm service in LIO-only mode"
fi
"${COMPOSE[@]}" up -d --no-build --no-deps --force-recreate algorithm
algorithm_id="$("${COMPOSE[@]}" ps -q algorithm)"
[[ -n "$algorithm_id" ]] || fail "algorithm container was not created"
wait_for_state "$algorithm_id" algorithm healthy

drivers_id="$("${COMPOSE[@]}" ps -q drivers)"
drivers_reusable=false
if [[ "$RESTART_DRIVERS" != "true" && -n "$drivers_id" ]]; then
  driver_state="$(docker inspect -f '{{.State.Status}}' "$drivers_id" 2>/dev/null || true)"
  driver_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$drivers_id" 2>/dev/null || true)"
  lidar_interface="$(sed -n 's/^LIDAR_INTERFACE=//p' <<< "$driver_env" | tail -n 1)"
  lidar_host_cidr="$(sed -n 's/^LIDAR_HOST_CIDR=//p' <<< "$driver_env" | tail -n 1)"
  lidar_device_ip="$(sed -n 's/^LIDAR_DEVICE_IP=//p' <<< "$driver_env" | tail -n 1)"
  driver_network_ok=false
  if [[ -n "$lidar_interface" && -n "$lidar_host_cidr" && -n "$lidar_device_ip" ]]; then
    driver_network_ready "$drivers_id" "$lidar_interface" "$lidar_host_cidr" "$lidar_device_ip" \
      && driver_network_ok=true || true
  fi
  expected_color=false
  [[ "$WITH_CAMERA" == "true" ]] && expected_color=true
  registered_nodes="$("${COMPOSE[@]}" exec -T roscore bash -lc \
    'source /opt/ros/noetic/setup.bash; rosnode list 2>/dev/null' || true)"
  if [[ "$driver_state" == "running" && "$driver_env" == *"ENABLE_LIVOX=true"* &&
        "$driver_env" == *"ENABLE_REALSENSE=true"* &&
        ( ( "$expected_color" == "true" && "$driver_env" == *"enable_color:=true"* ) ||
          ( "$expected_color" == "false" && "$driver_env" == *"enable_color:=false"* ) ) &&
        "$driver_network_ok" == "true" &&
        "$registered_nodes" == *"/livox_lidar_publisher"* &&
        "$registered_nodes" == *"/camera/realsense2_camera_manager"* ]]; then
    drivers_reusable=true
  fi
fi

if [[ "$drivers_reusable" == "true" ]]; then
  echo "[4/7] Reusing the running LiDAR/IMU driver container"
else
  echo "[4/7] Starting the LiDAR/IMU drivers after ROS Master is healthy"
  driver_state=""
  [[ -n "$drivers_id" ]] && driver_state="$(docker inspect -f '{{.State.Status}}' "$drivers_id" 2>/dev/null || true)"
  if [[ "$RESTART_DRIVERS" == "true" || "$driver_state" == "running" ]]; then
    "${COMPOSE[@]}" up -d --no-build --no-deps --force-recreate drivers
  else
    "${COMPOSE[@]}" up -d --no-build --no-deps drivers
  fi
  drivers_id="$("${COMPOSE[@]}" ps -q drivers)"
  [[ -n "$drivers_id" ]] || fail "drivers container was not created"
  wait_for_state "$drivers_id" drivers running
fi

ROS_ENV='source /opt/ros/noetic/setup.bash; source /opt/daib_ws/devel/setup.bash; export ROS_MASTER_URI=http://127.0.0.1:11311; export ROS_HOSTNAME=127.0.0.1; unset ROS_IP'

echo "[5/7] Cleaning stale ROS registrations"
"${COMPOSE[@]}" exec -T algorithm bash -lc \
  "$ROS_ENV; rosparam set /use_sim_time false; printf 'y\\n' | rosnode cleanup >/dev/null 2>&1 || true"

echo "[6/7] Validating LiDAR/IMU rates and timestamp alignment for ${CHECK_SECONDS}s"
DRIVER_ROS_ENV='source /opt/ros/noetic/setup.bash; source /opt/drivers_ws/devel/setup.bash; export ROS_MASTER_URI=http://127.0.0.1:11311; export ROS_HOSTNAME=127.0.0.1; unset ROS_IP'
TIMING_MODE="--lio-only"
[[ "$WITH_CAMERA" == "true" ]] && TIMING_MODE=""
if ! "${COMPOSE[@]}" exec -T drivers bash -lc \
    "$DRIVER_ROS_ENV; python3 /opt/drivers_ws/src/livox_ros_driver/scripts/check_sensor_timing.py --duration '$CHECK_SECONDS' $TIMING_MODE --validate"; then
  "${COMPOSE[@]}" logs --tail 120 algorithm drivers >&2 || true
  fail "LIO sensor timing validation failed"
fi

echo "[7/7] Verifying the laserMapping subscriptions and outputs"
node_info="$("${COMPOSE[@]}" exec -T algorithm bash -lc \
  "$ROS_ENV; rosnode info /laserMapping")"
grep -Fq '/livox/lidar' <<< "$node_info" \
  || fail "laserMapping is not subscribed to /livox/lidar"
grep -Fq '/camera/imu' <<< "$node_info" \
  || fail "laserMapping is not subscribed to /camera/imu"
# FAST-LIVO keeps a dormant image subscriber even when common/img_en=0.  It is
# harmless as long as no image transport connection is established.
camera_connections="$(grep -Fc '* topic: /camera/color/image_fast_livo' <<< "$node_info" || true)"
if [[ "$WITH_CAMERA" == "true" ]]; then
  for _ in $(seq 1 20); do
    (( camera_connections > 0 )) && break
    sleep 0.25
    node_info="$("${COMPOSE[@]}" exec -T algorithm bash -lc \
      "$ROS_ENV; rosnode info /laserMapping")"
    camera_connections="$(grep -Fc '* topic: /camera/color/image_fast_livo' <<< "$node_info" || true)"
  done
  (( camera_connections > 0 )) \
    || fail "laserMapping has no active camera transport in LIVO mode after 5s"
else
  if (( camera_connections > 0 )); then
    fail "laserMapping has an active camera transport in LIO-only mode"
  fi
fi

odom_type="$("${COMPOSE[@]}" exec -T algorithm bash -lc \
  "$ROS_ENV; rostopic type /daib_slam/odom")"
[[ "$odom_type" == "nav_msgs/Odometry" ]] \
  || fail "unexpected /daib_slam/odom type: ${odom_type}"

wifi_ip="$(ip -4 -o addr show dev wlan0 2>/dev/null | awk '{split($4, addr, "/"); print addr[1]; exit}')"
[[ -n "$wifi_ip" ]] || wifi_ip="<orange-pi-ip>"

echo
echo "[PASS] LIO-only stack is ready"
echo "  lidar:     /livox/lidar"
echo "  imu:       /camera/imu"
echo "  odometry:  /daib_slam/odom"
if [[ "$WITH_CAMERA" == "true" ]]; then
  echo "  camera:    enabled (/camera/color/image_raw)"
else
  echo "  camera:    disabled"
fi
if [[ "${LIO_ENABLE_FOXGLOVE:-true}" == "true" ]]; then
  echo "  Foxglove:  ws://${wifi_ip}:8765"
fi
