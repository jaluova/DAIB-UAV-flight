#!/usr/bin/env bash
# measure_livo_hz.sh — 结合实机启动命令，统计 FAST-LIVO 建图算法的每帧处理耗时，
# 回答"算法运行频率"问题。
#
# 背景:
#   LIVO 是逐帧触发架构（每帧 LiDAR 触发一次完整处理），算法运行频率
#   = 1 / 单帧处理耗时。每帧结束 LIVMapper.cpp 打印 "Current Total Time"
#   （青色 36m 行，LIO 整帧），vio.cpp 也会打印一行（绿色 32m，VIO 单独）。
#   100ms 是 MID-70 10Hz 帧间隔预算：平均耗时 < 100ms 才能跟上 10Hz。
#
# 用法:
#   scripts/measure_livo_hz.sh                 # 启动建图（daib-algorithm-adapter 容器），Ctrl+C 结束并统计
#   scripts/measure_livo_hz.sh --seconds 60    # 自动采样 60s 后统计
#   scripts/measure_livo_hz.sh --attach        # 不重启，跟随已有容器日志（docker logs -f）
#   scripts/measure_livo_hz.sh --log x.log     # 离线: 解析已有日志文件
#
# 选项:
#   --container NAME   容器名（默认 daib-algorithm-adapter）
#   --use-camera true|false   默认 true（use_camera:=true）
#   --extra ARGS       追加 roslaunch 参数，如 'vio_img_point_cov:=15000'
#   -h, --help

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="daib-algorithm-adapter"
USE_CAMERA="true"
EXTRA_ARGS=""
SECONDS_LIMIT=0
MODE="run"            # run | attach | log
LOG_FILE=""
TMP_LOG=""

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \?//'
}

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --seconds)
      (($# >= 2)) || fail "--seconds requires a value"
      SECONDS_LIMIT="$2"
      shift 2
      ;;
    --container)
      (($# >= 2)) || fail "--container requires a value"
      CONTAINER="$2"
      shift 2
      ;;
    --use-camera)
      (($# >= 2)) || fail "--use-camera requires true|false"
      USE_CAMERA="$2"
      shift 2
      ;;
    --extra)
      (($# >= 2)) || fail "--extra requires a value"
      EXTRA_ARGS="$2"
      shift 2
      ;;
    --attach)
      MODE="attach"
      shift
      ;;
    --log)
      (($# >= 2)) || fail "--log requires a path"
      MODE="log"
      LOG_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

ROS_ENV='source /opt/ros/noetic/setup.bash && source /opt/daib_ws/devel/setup.bash'
LAUNCH_CMD="roslaunch --screen fast_livo mapping_mid70_d435i.launch rviz:=false use_camera:=$USE_CAMERA $EXTRA_ARGS"

# --- 提取指定 ANSI 颜色段里 "Current Total Time" 的数值（秒） ---
# LIO 整帧行: \033[1;36m| Current Total Time | 0.030209 |\033[0m
# VIO 行:     \033[1;32m| Current Total Time | 0.022900 |\033[0m
extract_times() {  # $1=日志文件  $2=ANSI 颜色码(36/32)
  grep -a "Current Total Time" "$1" \
    | grep -a "1;${2}m" \
    | awk -F'|' '{gsub(/ /,"",$3); if ($3 ~ /^[0-9.]+$/) print $3}'
}

# --- 耗时统计: 平均/峰值/P95/最小 + 频率换算与 10Hz 判定 ---
summarize_series() {  # $1=名称  $2=数值文件(秒)  $3=是否按 10Hz 传感器判定
  local name="$1" f="$2" judge="$3"
  local n avg_ms peak_ms p95_ms min_ms hz_theory hz_actual
  n=$(wc -l <"$f" | tr -d ' ')
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || {
    echo "  $name: 无数据（LIVO 未出帧或日志未落盘，见下方诊断）"
    return 0
  }
  read -r avg_ms peak_ms p95_ms min_ms < <(sort -n "$f" | awk -v n="$n" '
    { a[NR]=$1*1000; s+=$1 }
    END{
      printf "%.1f %.1f %.1f %.1f\n",
        s/n*1000, a[n], a[int(n*0.95)], a[1]
    }') || true
  hz_theory=$(awk -v a="$avg_ms" 'BEGIN{printf "%.2f", 1000/a}')
  if [[ "$judge" == "10hz" ]]; then
    if awk -v a="$avg_ms" 'BEGIN{exit !(a<100)}'; then
      echo "  $name: 平均 ${avg_ms}ms  峰值 ${peak_ms}ms  P95 ${p95_ms}ms  最小 ${min_ms}ms  (${n} 帧)"
      echo "          处理上限 ${hz_theory}Hz → 传感器 10Hz 限制下可跟满 10Hz ✓ (预算 100ms)"
    else
      hz_actual=$(awk -v a="$avg_ms" -v t="$hz_theory" 'BEGIN{printf "%.2f", (t<10?t:10)}')
      echo "  $name: 平均 ${avg_ms}ms  峰值 ${peak_ms}ms  P95 ${p95_ms}ms  最小 ${min_ms}ms  (${n} 帧)"
      echo "          超预算！实际帧率约 ${hz_actual}Hz（目标 10Hz，需调参，参考 docs/fastlivo2-visual-selection.md）"
    fi
  else
    echo "  $name: 平均 ${avg_ms}ms  峰值 ${peak_ms}ms  P95 ${p95_ms}ms  最小 ${min_ms}ms  (${n} 帧)"
  fi
}

summarize() {
  local logf="$1" lio vio overall
  lio="$(mktemp)"; vio="$(mktemp)"
  extract_times "$logf" 36 >"$lio" || true
  extract_times "$logf" 32 >"$vio" || true
  echo "== 算法运行频率统计 (日志: $logf) =="
  summarize_series "LIO 整帧 (Current Total Time, 36m)" "$lio" 10hz
  summarize_series "VIO 单帧 (Current Total Time, 32m)" "$vio" ""
  # 全程累计平均（LIO 表格最后一行的 Average Total Time）作自洽参照
  overall="$(grep -a "Average Total Time" "$logf" | grep -a "1;36m" | tail -1 \
             | awk -F'|' '{gsub(/ /,"",$3); if ($3 ~ /^[0-9.]+$/) print $3*1000}')" || true
  if [[ -n "$overall" ]]; then
    echo "  累计平均参照 (Average Total Time): \${overall}ms"
  fi
  if ! grep -aq "Current Total Time" "$logf"; then
    echo "  [诊断] 日志中未找到 Current Total Time，可能 roslaunch 未启动或 LIVO 未出帧："
    echo "         tail -20 $logf"
    echo "         docker logs --tail 30 $CONTAINER"
    echo "         docker exec $CONTAINER bash -lc 'source /opt/ros/noetic/setup.bash; rosnode list'"
  fi
  rm -f "$lio" "$vio"
}

stop_launch() {  # 杀掉 docker exec 及容器内同名 roslaunch（无 tty 时 SIGINT 不会自动转发）
  kill "$run_pid" 2>/dev/null || true
  docker exec "$CONTAINER" bash -lc \
    "pkill -INT -f 'mapping_mid70_d435i.launch' 2>/dev/null || true" >/dev/null 2>&1 || true
}

run_mode() {
  [[ -n "$TMP_LOG" ]] || TMP_LOG="/tmp/livo-hz-$(date +%Y%m%d-%H%M%S).log"
  echo "[启动] docker exec -i $CONTAINER → $LAUNCH_CMD"
  echo "[日志] $TMP_LOG   (Ctrl+C 或 ${SECONDS_LIMIT}s 后自动统计)"
  docker exec -i "$CONTAINER" bash -lc "$ROS_ENV && $LAUNCH_CMD" >"$TMP_LOG" 2>&1 &
  local run_pid=$!
  if [[ "$SECONDS_LIMIT" -gt 0 ]]; then
    ( sleep "$SECONDS_LIMIT"; stop_launch ) &
  fi
  trap 'stop_launch; summarize "'"$TMP_LOG"'"; exit 0' INT TERM
  wait "$run_pid" 2>/dev/null || true
  stop_launch
  summarize "$TMP_LOG"
  exit 0
}

attach_mode() {
  TMP_LOG="/tmp/livo-hz-attach-$(date +%Y%m%d-%H%M%S).log"
  echo "[跟随] docker logs -f --since 0s $CONTAINER → $TMP_LOG (Ctrl+C 或 ${SECONDS_LIMIT}s 后统计)"
  docker logs -f --since 0s "$CONTAINER" >"$TMP_LOG" 2>&1 &
  local run_pid=$!
  if [[ "$SECONDS_LIMIT" -gt 0 ]]; then
    ( sleep "$SECONDS_LIMIT"; kill "$run_pid" 2>/dev/null || true ) &
  fi
  trap 'kill "'"$run_pid"'" 2>/dev/null || true; summarize "'"$TMP_LOG"'"; exit 0' INT TERM
  wait "$run_pid" 2>/dev/null || true
  summarize "$TMP_LOG"
  exit 0
}

case "$MODE" in
  log)
    [[ -r "$LOG_FILE" ]] || fail "日志文件不可读: $LOG_FILE"
    summarize "$LOG_FILE"
    ;;
  attach)
    attach_mode
    ;;
  *)
    run_mode
    ;;
esac
