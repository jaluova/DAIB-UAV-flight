# Indoor3 FAST-LIVO2 + EGO 当前多终端运行流程

日期：2026-08-03

## 1. 适用版本与接口

本文只适用于当前本地恢复并合并后的 FAST-LIVO2 稳定版本：

```text
DAIB-LIVO commit: 9883f56
map_sliding_en: false
PVBSM: disabled/removed from the runtime tree
```

当前 FAST-LIVO2 使用原始输出接口，不使用旧文档中的
`/daib_slam/imu_odom`和`/daib_slam/planning_cloud`：

```text
SLAM odom:   /aft_mapped_to_init      (camera_init -> aft_mapped)
SLAM cloud:  /cloud_registered        (camera_init)
PX4 odom:    /iris_0/mavros/local_position/odom (map)
EGO odom:    /daib_px4/odom_camera_init (camera_init, simulation relabel only)
EGO command: /xtdrone/iris_0/cmd_pose_enu
```

`px4_odom_camera_init.py`只在仿真出生点对齐时检查 PX4 和 SLAM 的起始位置，
然后把 PX4 odom 的 frame 标记为`camera_init`。它不估计真正的
`map -> camera_init`变换，SLAM 重启后必须重新启动适配器和 EGO。

## 2. 当前外参核对结果

实际仿真模型文件：

```text
/root/PX4_Firmware/Tools/sitl_gazebo/models/iris_realsense_livox/iris_realsense_livox.sdf
/root/PX4_Firmware/Tools/sitl_gazebo/models/realsense_camera/realsense_camera.sdf
/root/PX4_Firmware/Tools/sitl_gazebo/models/livox_avia/livox_avia.sdf
```

模型中各传感器中心在`base_link`下的位置为：

```text
LiDAR:           [0.05, 0.00, 0.095] m
Realsense link:  [0.10, 0.00, 0.000] m
Realsense IMU:   [0.10, 0.00, 0.300] m
Left camera:     [0.10, 0.06, 0.000] m
```

LiDAR、IMU和机体模型轴方向相同，因此：

```text
p_imu = R_il * p_lidar + T_il
R_il = I
T_il = [0.05, 0, 0.095] - [0.10, 0, 0.30]
     = [-0.05, 0, -0.205] m
```

Gazebo相机体坐标为`X前、Y左、Z上`，光学坐标为`X右、Y下、Z前`：

```text
Rcl = [ 0 -1  0
        0  0 -1
        1  0  0 ]

Pcl = Rcl * ([0.05, 0, 0.095] - [0.10, 0.06, 0])
    = [0.06, -0.095, -0.05] m
```

当前`mapping_avia_sim.launch`中的外参数值与模型一致。启动时必须显式传入：

```text
use_xtdrone_lidar_imu_extrinsic:=true
use_xtdrone_camera_extrinsic:=true
```

相机模型为`752 x 480`，仿真插件给出的内参为：

```text
fx=376, fy=376, cx=376, cy=240
k1=-0.1, k2=0.01, p1=0.00005, p2=-0.0001
```

FAST-LIVO2配置的`fx/fy=375.9986`与插件仅相差约`0.0014`，可视为一致。
`img_time_offset`不是外参；当前仿真使用`0.0 s`，仍应通过飞行日志单独检查图像和
LiDAR时间同步。

## 3. EGO障碍膨胀

`daib_manual.launch`当前默认参数：

```text
map_resolution:       0.25 m
obstacles_inflation:  0.3 m
```

EGO实现使用：

```text
inflation_steps = ceil(obstacles_inflation / map_resolution)
```

因此当前为2个体素，即障碍点在每个坐标方向形成约`0.5 m`的离散保护距离。
由于实现按体素取整，在保持`0.25 m`地图分辨率时，将参数提高到大于`0.5 m`
会直接变为3个体素、约`0.75 m`，所以当前保留原来的`0.3 m`设置。

## 4. 所有终端的公共环境

先在宿主机执行一次：

```bash
docker start ros1-rviz
```

之后每个新终端都先执行：

```bash
docker exec -it ros1-rviz bash
source /root/daib_env.sh
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP
```

不要单独启动`roscore`，终端1的 PX4 launch 会自动启动 ROS Master。

## 5. 终端1：PX4、Indoor3、Gazebo和MAVROS

```bash
export DISPLAY=:0
roslaunch px4 indoor3_my.launch
```

等待 Gazebo 完全加载。此时不要移动无人机。

## 6. 终端2：XTDrone communication

```bash
cd /root/XTDrone/communication
python3 multirotor_communication.py iris 0
```

## 7. 终端3：FAST-LIVO2完整LIVO

启动期间保持无人机静止：

```bash
roslaunch fast_livo mapping_avia_sim.launch \
  rviz:=false \
  img_en:=1 \
  blind:=0.4 \
  img_time_offset:=0.0 \
  use_xtdrone_lidar_imu_extrinsic:=true \
  use_xtdrone_camera_extrinsic:=true
```

应持续看到：

```text
Get LiDAR
Get image
[ VIO ] Raw feature num
[ VIO ] Update Visual Map
```

只做纯LIO A/B测试时，将终端3替换为：

```bash
roslaunch fast_livo mapping_avia_sim.launch \
  rviz:=false \
  img_en:=0 \
  blind:=0.4 \
  img_time_offset:=0.0 \
  use_xtdrone_lidar_imu_extrinsic:=true
```

## 8. 终端4：PX4 odom仿真起点适配

先确认当前恢复版接口确实有数据。每条命令观察数秒后按`Ctrl-C`：

```bash
rostopic hz /aft_mapped_to_init
rostopic hz /cloud_registered
rostopic hz /iris_0/mavros/local_position/odom
```

然后启动适配器，并显式指定当前SLAM odom：

```bash
rosrun ego_planner px4_odom_camera_init.py \
  _slam_odom_topic:=/aft_mapped_to_init
```

必须等待：

```text
PX4/SLAM start alignment accepted
Publishing /daib_px4/odom_camera_init
```

若报起点误差大于`0.5 m`，不要启动EGO。将无人机恢复到出生点，依次重启
FAST-LIVO2、适配器和EGO。

## 9. 终端5：键盘起飞和人工调整

```bash
cd /root/XTDrone/control/keyboard
python3 multirotor_keyboard_control.py iris 1 vel
```

使用键盘起飞并进入稳定悬停。准备发送EGO目标之前，必须在本终端按`Ctrl-C`。
XTDrone communication没有控制权仲裁，键盘和EGO同时运行会竞争控制目标。

## 10. 终端6：EGO手动目标规划

确认键盘节点已经停止后执行：

```bash
roslaunch ego_planner daib_manual.launch \
  use_sim_time:=true \
  odom_topic:=/daib_px4/odom_camera_init \
  cloud_topic:=/cloud_registered \
  world_frame:=camera_init \
  require_planning_input_valid:=false \
  traj_server_pose_cmd_topic:=/xtdrone/iris_0/cmd_pose_enu \
  obstacles_inflation:=0.3 \
  max_vel:=0.3 \
  max_acc:=0.5 \
  max_yaw_rate:=0.35 \
  odom_timeout_s:=0.6 \
  cloud_timeout_s:=1.0
```

这里关闭`require_planning_input_valid`是因为当前恢复版没有发布
`/daib_px4/planning_input_valid`。该链路是当前仿真A/B链路，不等同于未来
带时间插值点云桥的正式`map`闭环。

## 11. 终端7：RViz

```bash
export DISPLAY=:0
rviz -d /root/fast_livo2.rviz
```

确认RViz的`Fixed Frame`为`camera_init`。键盘停止、SLAM点云和适配odom持续更新
后，再使用`2D Nav Goal`发送同高度目标。第一次只测试`1-2 m`短目标，并避免贴墙
高速旋转。

## 12. 启动后检查

另开终端并执行公共环境命令，然后检查：

```bash
rostopic hz /scan
rostopic hz /iris_0/imu_gazebo
rostopic hz /iris_0/stereo_camera/left/image_raw
rostopic hz /aft_mapped_to_init
rostopic hz /cloud_registered
rostopic hz /iris_0/mavros/local_position/odom
rostopic hz /daib_px4/odom_camera_init
```

检查frame：

```bash
rostopic echo -n 1 /aft_mapped_to_init/header
rostopic echo -n 1 /cloud_registered/header
rostopic echo -n 1 /daib_px4/odom_camera_init/header
```

预期：

```text
/aft_mapped_to_init:          camera_init
/cloud_registered:           camera_init
/daib_px4/odom_camera_init:  camera_init
```

检查膨胀参数：

```bash
rosparam get /drone_0_ego_planner_node/grid_map/obstacles_inflation
rosparam get /drone_0_ego_planner_node/grid_map/resolution
```

预期：

```text
0.3
0.25
```

检查只有一个MAVROS setpoint发布者：

```bash
rostopic info /xtdrone/iris_0/cmd_pose_enu
rostopic info /iris_0/mavros/setpoint_raw/local
```

发送目标前，`/iris_0/mavros/setpoint_raw/local`应只有
`/iris_0_communication`一个发布者。

## 13. 常见故障

### 适配器一直等待FAST-LIVO odom

确认使用了：

```bash
rosrun ego_planner px4_odom_camera_init.py \
  _slam_odom_topic:=/aft_mapped_to_init
```

不要使用已删除的默认旧话题`/daib_slam/imu_odom`。

### EGO没有点云

当前恢复版使用：

```text
cloud_topic:=/cloud_registered
```

不要使用已删除的`/daib_slam/planning_cloud`。

### EGO等待planning input valid

当前A/B链路必须显式传入：

```text
require_planning_input_valid:=false
```

### 飞机被认为位于障碍内

先在RViz观察：

```text
/drone_0_ego_planner_node/grid_map/occupancy
/drone_0_ego_planner_node/grid_map/occupancy_inflate
```

若原始occupancy正常但inflated map包住飞机，临时使用：

```text
obstacles_inflation:=0.3
```

若原始occupancy本身随飞机移动或跳动，应先排查SLAM和点云frame，不应继续增加
膨胀距离。

## 14. 停止顺序

依次在EGO、适配器、FAST-LIVO2、communication和PX4终端按`Ctrl-C`。确认所有
ROS进程退出后，在宿主机执行：

```bash
docker stop ros1-rviz
```
