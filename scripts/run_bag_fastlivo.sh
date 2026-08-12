#!/bin/bash
# 本机回放 bag + FAST-LIVO（batch2 外参）+ Foxglove
set -e

IMG=localhost:5050/daib-algorithm:gpsless-cleanup-3f7e07c-openeuler-arm64
BAG_DIR=/Users/unf01d/cc-chat/bags/fast_livo_real/20260807_162735
BAG_FILE=/bags/fast_livo_inputs_20260807_162735_0.bag
LIVO_CFG=/Users/unf01d/cc-chat/src/DAIB-LIVO/config/mid70_d435i.yaml

# 清理旧容器
for c in ros-master bag-play fast-livo foxglove; do
  docker rm -f $c >/dev/null 2>&1 || true
done

# 1. roscore
docker run -d --name ros-master --network host --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 -e ROS_HOSTNAME=127.0.0.1 \
  $IMG -lc 'source /opt/ros/noetic/setup.bash; exec roscore'

# 2. bag 循环播放
docker run -d --name bag-play --network host --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 -e ROS_HOSTNAME=127.0.0.1 \
  -v "$BAG_DIR":/bags \
  $IMG -lc "source /opt/ros/noetic/setup.bash; exec rosbag play --loop $BAG_FILE"

# 3. FAST-LIVO（batch2 外参）
docker run -d --name fast-livo --network host --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 -e ROS_HOSTNAME=127.0.0.1 \
  -v "$LIVO_CFG":/opt/daib_ws/src/fast_livo/config/mid70_d435i.yaml \
  $IMG -lc 'source /opt/ros/noetic/setup.bash && source /opt/daib_ws/devel/setup.bash && roslaunch fast_livo mapping_mid70_d435i.launch rviz:=false use_camera:=true vio_img_point_cov:=15000'

# 4. Foxglove bridge
docker run -d --name foxglove --network host --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 -e ROS_HOSTNAME=127.0.0.1 \
  $IMG -lc 'source /opt/ros/noetic/setup.bash && source /opt/foxglove_ws/devel/setup.bash && roslaunch foxglove_bridge foxglove_bridge.launch port:=8765'

echo "=== 容器已启动 ==="
echo "验证 cov:   docker exec fast-livo bash -lc 'source /opt/ros/noetic/setup.bash && rosparam get /vio/img_point_cov'"
echo "看日志:     docker logs -f fast-livo"
echo "Foxglove:   ws://127.0.0.1:8765"
