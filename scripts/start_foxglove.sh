#!/bin/bash
docker rm -f foxglove >/dev/null 2>&1 || true
docker run -d --name foxglove --network host --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 -e ROS_HOSTNAME=127.0.0.1 \
  localhost:5050/daib-algorithm:gpsless-cleanup-3f7e07c-openeuler-arm64 \
  -lc 'source /opt/ros/noetic/setup.bash && source /opt/foxglove_ws/devel/setup.bash && roslaunch foxglove_bridge foxglove_bridge.launch port:=8765'
echo "foxglove started"
