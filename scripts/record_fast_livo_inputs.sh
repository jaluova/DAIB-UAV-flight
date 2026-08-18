#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${DAIB_COMPOSE_FILE:-${REPO_ROOT}/deploy/compose.orange-pi-5-max.yml}"
ENV_FILE="${DAIB_ENV_FILE:-${REPO_ROOT}/deploy/.env}"
OUTPUT_ROOT=""
MIN_FREE_GB=10
MAX_MINUTES=0
CHECK_INTERVAL_SECONDS=5
START_IMAGE_THROTTLE=false
INCLUDE_RAW_IMAGE=false

TOPICS=(
  /livox/lidar
  /camera/imu
  /camera/color/image_fast_livo
)

usage() {
  cat <<'EOF'
Usage: record_fast_livo_inputs.sh [options]

Options:
  --output-dir DIR   Host output directory (default: BAGS_DIR/fast_livo_real)
  --min-free-gb N    Stop before free space falls below N GiB (default: 10)
  --max-minutes N    Stop after N minutes; 0 means Ctrl+C only (default: 0)
  --include-raw-image
                     Also record /camera/color/image_raw (about 30 Hz) for
                     near-real-time replay; increases bag size substantially
  -h, --help         Show this help
EOF
}

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --output-dir)
      (($# >= 2)) || fail "--output-dir requires a path"
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --min-free-gb)
      (($# >= 2)) || fail "--min-free-gb requires a number"
      MIN_FREE_GB="$2"
      shift 2
      ;;
    --max-minutes)
      (($# >= 2)) || fail "--max-minutes requires a number"
      MAX_MINUTES="$2"
      shift 2
      ;;
    --include-raw-image)
      INCLUDE_RAW_IMAGE=true
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

[[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] \
  || fail "--min-free-gb must be an integer"
[[ "$MAX_MINUTES" =~ ^[0-9]+$ ]] \
  || fail "--max-minutes must be an integer"
(( MIN_FREE_GB >= 1 && MIN_FREE_GB <= 1000 )) \
  || fail "--min-free-gb must be between 1 and 1000"
(( MAX_MINUTES >= 0 && MAX_MINUTES <= 1440 )) \
  || fail "--max-minutes must be between 0 and 1440"

if [[ "$INCLUDE_RAW_IMAGE" == "true" ]]; then
  TOPICS+=(/camera/color/image_raw)
fi

[[ "$(uname -s)" == "Linux" ]] \
  || fail "this script must run on the Orange Pi Linux host"
command -v docker >/dev/null || fail "docker is not installed"
docker info >/dev/null 2>&1 || fail "the Docker daemon is not reachable"
[[ -r "$COMPOSE_FILE" ]] || fail "compose file is not readable: ${COMPOSE_FILE}"
[[ -r "$ENV_FILE" ]] || fail "runtime environment file is not readable: ${ENV_FILE}"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
elif command -v docker-compose >/dev/null; then
  COMPOSE=(docker-compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
else
  fail "Docker Compose is not installed"
fi

algorithm_id="$("${COMPOSE[@]}" ps -q algorithm)"
[[ -n "$algorithm_id" ]] || fail "algorithm service is not running"
[[ "$(docker inspect -f '{{.State.Running}}' "$algorithm_id")" == "true" ]] \
  || fail "algorithm service is not running"

if [[ -z "$OUTPUT_ROOT" ]]; then
  bags_source="$(docker inspect -f \
    '{{range .Mounts}}{{if eq .Destination "/bags"}}{{.Source}}{{end}}{{end}}' \
    "$algorithm_id")"
  [[ -n "$bags_source" ]] \
    || fail "algorithm container has no host directory mounted at /bags"
  OUTPUT_ROOT="${bags_source}/fast_livo_real"
fi

mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd -- "$OUTPUT_ROOT" && pwd)"

LOCK_DIR=/tmp/daib-record-fast-livo.lock
mkdir "$LOCK_DIR" 2>/dev/null \
  || fail "another FAST-LIVO input recording is already running"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

ROS_ENV='source /opt/ros/noetic/setup.bash; source /opt/daib_ws/devel/setup.bash; export ROS_MASTER_URI=http://127.0.0.1:11311; export ROS_HOSTNAME=127.0.0.1; unset ROS_IP'
TIMING_ROS_ENV='source /opt/ros/noetic/setup.bash; source /opt/drivers_ws/devel/setup.bash; export ROS_MASTER_URI=http://127.0.0.1:11311; export ROS_HOSTNAME=127.0.0.1; unset ROS_IP'
TIMING_CHECKER='/opt/drivers_ws/src/livox_ros_driver/scripts/check_sensor_timing.py'

echo "[1/4] Checking required FAST-LIVO topics"
for topic in /livox/lidar /camera/imu; do
  topic_type="$("${COMPOSE[@]}" exec -T algorithm bash -lc \
    "$ROS_ENV; rostopic type '$topic' 2>/dev/null")" \
    || fail "topic is unavailable: ${topic}"
  [[ -n "$topic_type" ]] || fail "topic has no type: ${topic}"
  printf '  %-38s %s\n' "$topic" "$topic_type"
done

timing_log="$(mktemp)"
trap 'rm -f "$timing_log"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
if "${COMPOSE[@]}" exec -T drivers bash -lc \
    "$TIMING_ROS_ENV; python3 '$TIMING_CHECKER' --duration 4 --warmup 0.5 --validate \
      --image-topic /camera/color/image_fast_livo \
      --image-rate-min 8 --image-rate-max 12 \
      --image-nearest-max-ms 60" >"$timing_log" 2>&1; then
  image_type="$("${COMPOSE[@]}" exec -T algorithm bash -lc \
    "$ROS_ENV; rostopic type /camera/color/image_fast_livo")"
  printf '  %-38s %s (existing 10 Hz stream)\n' \
    /camera/color/image_fast_livo "$image_type"
else
  image_type="$("${COMPOSE[@]}" exec -T algorithm bash -lc \
    "$ROS_ENV; rostopic type /camera/color/image_raw 2>/dev/null")" \
    || fail "neither FAST-LIVO nor raw camera image is available"
  [[ "$image_type" == "sensor_msgs/Image" ]] \
    || fail "unexpected raw image type: ${image_type}"
  "${COMPOSE[@]}" exec -T drivers bash -lc \
    "$TIMING_ROS_ENV; python3 '$TIMING_CHECKER' --duration 4 --warmup 0.5 --validate" \
    >"$timing_log" 2>&1 || {
      cat "$timing_log" >&2
      fail "LiDAR, IMU or raw camera stream failed timing validation"
    }
  START_IMAGE_THROTTLE=true
  printf '  %-38s %s (recorder will create a 10 Hz stream)\n' \
    /camera/color/image_fast_livo "$image_type"
fi
cat "$timing_log"
rm -f "$timing_log"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

if [[ "$INCLUDE_RAW_IMAGE" == "true" ]]; then
  raw_timing_log="$(mktemp)"
  if ! "${COMPOSE[@]}" exec -T drivers bash -lc \
      "$TIMING_ROS_ENV; python3 '$TIMING_CHECKER' --duration 4 --warmup 0.5 --validate \
        --image-topic /camera/color/image_raw \
        --image-rate-min 20 --image-rate-max 35 \
        --image-nearest-max-ms 100" >"$raw_timing_log" 2>&1; then
    cat "$raw_timing_log" >&2
    rm -f "$raw_timing_log"
    fail "raw camera image timing validation failed"
  fi
  cat "$raw_timing_log"
  rm -f "$raw_timing_log"
  raw_image_type="$(${COMPOSE[@]} exec -T algorithm bash -lc \
    "$ROS_ENV; rostopic type /camera/color/image_raw")"
  printf '  %-38s %s (recording raw camera frames)\n' \
    /camera/color/image_raw "$raw_image_type"
fi

available_kib="$(df -Pk "$OUTPUT_ROOT" | awk 'NR == 2 {print $4}')"
[[ "$available_kib" =~ ^[0-9]+$ ]] || fail "could not determine free disk space"
AVAILABLE_BYTES=$((available_kib * 1024))
MIN_FREE_BYTES=$((MIN_FREE_GB * 1024 * 1024 * 1024))
START_REQUIRED_BYTES=$(((MIN_FREE_GB + 2) * 1024 * 1024 * 1024))
(( AVAILABLE_BYTES > START_REQUIRED_BYTES )) \
  || fail "only $((AVAILABLE_BYTES / 1024 / 1024 / 1024)) GiB free; need more than $((MIN_FREE_GB + 2)) GiB"

SESSION_STAMP="$(date +%Y%m%d_%H%M%S)"
SESSION_DIR="${OUTPUT_ROOT}/${SESSION_STAMP}"
BAG_PREFIX="fast_livo_inputs_${SESSION_STAMP}"
METADATA_FILE="${SESSION_DIR}/session_metadata.txt"
RECORDER_CONTAINER="daib-fast-livo-recorder-${SESSION_STAMP}-$$"
RECORDER_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$algorithm_id")"
mkdir -p "$SESSION_DIR"

stop_recorder() {
  if [[ "$(docker inspect -f '{{.State.Running}}' "$RECORDER_CONTAINER" 2>/dev/null || true)" == "true" ]]; then
    docker kill --signal=SIGINT "$RECORDER_CONTAINER" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      [[ "$(docker inspect -f '{{.State.Running}}' "$RECORDER_CONTAINER" 2>/dev/null || true)" != "true" ]] && return
      sleep 1
    done
    docker stop --time 10 "$RECORDER_CONTAINER" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  stop_recorder
  "${COMPOSE[@]}" exec -T algorithm bash -lc \
    "$ROS_ENV; printf 'y\\n' | rosnode cleanup >/dev/null 2>&1" || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

echo "[2/4] Recording session metadata"
{
  echo "session=${SESSION_STAMP}"
  echo "start_time_local=$(date --iso-8601=ns)"
  echo "start_time_epoch_ns=$(date +%s%N)"
  echo "hostname=$(hostname)"
  echo "recorder_image=${RECORDER_IMAGE}"
  echo "output_dir=${SESSION_DIR}"
  echo "minimum_free_gib=${MIN_FREE_GB}"
  echo "internal_image_throttle=${START_IMAGE_THROTTLE}"
  echo "topics=${TOPICS[*]}"
  echo
  echo "filesystem_at_start:"
  df -hT "$OUTPUT_ROOT"
  echo
} > "$METADATA_FILE"

echo "[3/4] Starting host-mounted rosbag recorder"
THROTTLE_COMMAND=""
if [[ "$START_IMAGE_THROTTLE" == "true" ]]; then
  THROTTLE_COMMAND="rosrun topic_tools throttle messages /camera/color/image_raw 10.0 /camera/color/image_fast_livo >/tmp/fast-livo-image-throttle.log 2>&1 &"
fi
docker run -d \
  --name "$RECORDER_CONTAINER" \
  --network host \
  --volume "${SESSION_DIR}:/bags" \
  --entrypoint /bin/bash \
  "$RECORDER_IMAGE" -lc \
  "source /opt/ros/noetic/setup.bash; source /opt/daib_ws/devel/setup.bash; export ROS_MASTER_URI=http://127.0.0.1:11311; export ROS_HOSTNAME=127.0.0.1; unset ROS_IP; ${THROTTLE_COMMAND} exec rosbag record --lz4 --split --size=4096 --buffsize=512 -O '/bags/${BAG_PREFIX}' ${TOPICS[*]}" \
  >/dev/null
trap cleanup EXIT

STOP_REASON=recorder_exited
STOP_REQUESTED=false
START_MONOTONIC="$(date +%s)"

{
  echo "recorder_started_time_local=$(date --iso-8601=ns)"
  echo "recorder_started_time_epoch_ns=$(date +%s%N)"
  echo
  echo "sensor_timing_after_recorder_start:"
} >> "$METADATA_FILE"

"${COMPOSE[@]}" exec -T drivers bash -lc \
  "$TIMING_ROS_ENV; python3 '$TIMING_CHECKER' --duration 2 --warmup 0.5 \
    --image-topic /camera/color/image_fast_livo \
    --image-rate-min 8 --image-rate-max 12 \
    --image-nearest-max-ms 60" \
  >> "$METADATA_FILE" 2>&1 || echo "sensor_timing=unavailable" >> "$METADATA_FILE"

request_stop() {
  STOP_REASON="manual Ctrl+C"
  STOP_REQUESTED=true
}
trap request_stop INT TERM

echo "[4/4] Recording"
echo "  output: ${SESSION_DIR}"
echo "  free:   $((AVAILABLE_BYTES / 1024 / 1024 / 1024)) GiB"
echo "  stop:   press Ctrl+C"

while [[ "$(docker inspect -f '{{.State.Running}}' "$RECORDER_CONTAINER" 2>/dev/null || true)" == "true" ]]; do
  sleep "$CHECK_INTERVAL_SECONDS" &
  wait $! || true
  [[ "$STOP_REQUESTED" == "true" ]] && break

  available_kib="$(df -Pk "$OUTPUT_ROOT" | awk 'NR == 2 {print $4}')"
  AVAILABLE_BYTES=$((available_kib * 1024))
  if (( AVAILABLE_BYTES <= MIN_FREE_BYTES )); then
    STOP_REASON="low disk space"
    echo "[WARN] Free space reached ${MIN_FREE_GB} GiB; stopping safely"
    break
  fi

  if (( MAX_MINUTES > 0 && $(date +%s) - START_MONOTONIC >= MAX_MINUTES * 60 )); then
    STOP_REASON="maximum duration"
    echo "[INFO] Maximum duration reached; stopping safely"
    break
  fi
done

stop_recorder
"${COMPOSE[@]}" exec -T algorithm bash -lc \
  "$ROS_ENV; printf 'y\\n' | rosnode cleanup >/dev/null 2>&1" || true
trap - EXIT INT TERM
rmdir "$LOCK_DIR" 2>/dev/null || true

RECORDER_EXIT_CODE="$(docker inspect -f '{{.State.ExitCode}}' "$RECORDER_CONTAINER" 2>/dev/null || echo unknown)"
docker logs "$RECORDER_CONTAINER" > "${SESSION_DIR}/rosbag_record.log" 2>&1 || true
docker rm "$RECORDER_CONTAINER" >/dev/null 2>&1 || true

{
  echo
  echo "end_time_local=$(date --iso-8601=ns)"
  echo "end_time_epoch_ns=$(date +%s%N)"
  echo "stop_reason=${STOP_REASON}"
  echo "recorder_exit_code=${RECORDER_EXIT_CODE}"
  echo
  echo "filesystem_at_end:"
  df -hT "$OUTPUT_ROOT"
  echo
  echo "recorded_files:"
  find "$SESSION_DIR" -maxdepth 1 -type f -printf '%f %s bytes\n' | sort
} >> "$METADATA_FILE"

mapfile -t BAG_FILES < <(find "$SESSION_DIR" -maxdepth 1 -type f -name '*.bag' -print | sort)
if ((${#BAG_FILES[@]} == 0)); then
  fail "no finalized bag file was created; inspect ${SESSION_DIR}/rosbag_record.log"
fi
if find "$SESSION_DIR" -maxdepth 1 -type f -name '*.bag.active' | grep -q .; then
  fail "an active bag remains; recording was not finalized cleanly"
fi

TOTAL_BYTES="$(du -sb "$SESSION_DIR" | awk '{print $1}')"
echo
echo "[PASS] Recording finalized"
echo "  reason: ${STOP_REASON}"
echo "  size:   $(numfmt --to=iec-i --suffix=B "$TOTAL_BYTES")"
echo "  files:  ${#BAG_FILES[@]} bag(s)"
echo "  path:   ${SESSION_DIR}"
echo "  meta:   ${METADATA_FILE}"
