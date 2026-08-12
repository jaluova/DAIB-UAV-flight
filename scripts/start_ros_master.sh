#!/bin/bash
docker rm -f ros-master >/dev/null 2>&1 || true
docker run -d --name ros-master --network host --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 -e ROS_HOSTNAME=127.0.0.1 \
  localhost:5050/daib-algorithm:gpsless-cleanup-3f7e07c-openeuler-arm64 \
  -lc 'source /opt/ros/noetic/setup.bash; exec roscore'
echo "ros-master started"
