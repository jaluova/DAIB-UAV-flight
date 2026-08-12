#!/bin/bash
docker rm -f bag-play >/dev/null 2>&1 || true
docker run -d --name bag-play --network host --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 -e ROS_HOSTNAME=127.0.0.1 \
  -v /Users/unf01d/cc-chat/bags/fast_livo_real/20260807_162735:/bags \
  localhost:5050/daib-algorithm:gpsless-cleanup-3f7e07c-openeuler-arm64 \
  -lc 'source /opt/ros/noetic/setup.bash; exec rosbag play /bags/fast_livo_inputs_20260807_162735_0.bag'
echo "bag-play started"
