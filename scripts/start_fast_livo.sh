#!/bin/bash
docker rm -f fast-livo >/dev/null 2>&1 || true
docker run -d --name fast-livo --network host --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 -e ROS_HOSTNAME=127.0.0.1 \
  -v /Users/unf01d/cc-chat/src/DAIB-LIVO/config/mid70_d435i.yaml:/opt/daib_ws/src/fast_livo/config/mid70_d435i.yaml \
  localhost:5050/daib-algorithm:gpsless-cleanup-3f7e07c-openeuler-arm64 \
  -lc 'source /opt/ros/noetic/setup.bash && source /opt/daib_ws/devel/setup.bash && roslaunch fast_livo mapping_mid70_d435i.launch rviz:=false use_camera:=true vio_img_point_cov:=15000'
echo "fast-livo started"
