#!/usr/bin/env bash
# Record a map-accuracy validation bag on the Orange Pi.
#
# Correct standalone recorder per docs/orange-pi-d435i-mid70-fast-livo-runbook-20260811.md
# section 14.3: independent recorder container, NO rostopic echo (broken rospy
# toolchain on the board). Run this on the Orange Pi while FAST-LIVO is running.
#
# Usage:
#   ./record_map_accuracy.sh            # records until Ctrl+C
#   ./record_map_accuracy.sh 90         # auto-stop after 90 s
#
# Output: /mnt/ssd/bags/map_acc_<ts>.bag  (mounted into the container as /bags)

set -euo pipefail

DURATION="${1:-}"
BAG_NAME="map_acc_$(date +%Y%m%d_%H%M%S)"

# Required: per-frame registered cloud. Optional extras are commented below.
TOPICS=(
  /cloud_registered
  # /Laser_map                     # global accumulated map, IF this build publishes it
  # /livox/lidar                   # raw lidar (for offline re-build, doubles bag size)
  # /camera/imu
  # /camera/color/image_fast_livo  # 10 Hz image FAST-LIVO actually consumes
)

RECORD_CMD="source /opt/ros/noetic/setup.bash; exec rosbag record --lz4 --split --size=4096 --buffsize=512 -O /bags/${BAG_NAME} ${TOPICS[*]}"
if [ -n "$DURATION" ]; then
  RECORD_CMD="source /opt/ros/noetic/setup.bash; timeout -s INT ${DURATION} rosbag record --lz4 --split --size=4096 --buffsize=512 -O /bags/${BAG_NAME} ${TOPICS[*]}"
fi

echo "recording -> /mnt/ssd/bags/${BAG_NAME}  topics: ${TOPICS[*]}"

docker run --rm -it \
  --name daib-recorder \
  --network host \
  --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 \
  -e ROS_HOSTNAME=127.0.0.1 \
  -e BAG_NAME="$BAG_NAME" \
  -v /mnt/ssd/bags:/bags \
  192.168.218.119:5050/daib-algorithm:openeuler-arm64 \
  -lc "$RECORD_CMD"

# rosbag record exits on SIGINT only after writing its index; the file is done
# when no /mnt/ssd/bags/${BAG_NAME}.bag.active remains.
echo "done; verify: ls -lh /mnt/ssd/bags/${BAG_NAME}*"
