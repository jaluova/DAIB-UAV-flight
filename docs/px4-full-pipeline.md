# PX4 + XTDrone + EGO-Planner 环境与感知链路

> 控制架构已重新决策。本文保留环境、感知和手动测试启动信息，不再描述
> EGO 到 PX4 的自动执行层。参见 `ego-px4-control-architecture.md`。

## 架构

```
本机 (ros1-gazebo 容器)                  开发板 (ros1_dev)
┌──────────────────────────────┐        ┌──────────────────────────────┐
│ PX4 SITL + Gazebo            │        │ roscore :11311               │
│ iris_realsense_livox 模型    │        │                              │
│   ↓ LiDAR / IMU / Camera     │  TCP   │ fast_livo (SLAM)            │
│ MAVROS / manual XTDrone test │───────▶│ daib_explorer               │
│   ↓ /iris_0/mavros/*         │        │ ego_planner (planning only) │
│ multirotor_keyboard_control  │        │                              │
│ rviz (本机 GPU)              │◀───────│ laserMap, odom, path         │
└──────────────────────────────┘        └──────────────────────────────┘
```

## 启动顺序

### 开发板端 (192.168.0.2)

4 个终端依次进 `ros1_dev`：

```bash
ssh root@192.168.0.2
docker start ros1_dev
docker exec -it ros1_dev bash

# 终端 1 - roscore
source ~/catkin_ws/devel/setup.bash && roscore

# 终端 2 - FAST-LIVO2 SLAM
source ~/catkin_ws/devel/setup.bash && roslaunch fast_livo mapping_avia.launch rviz:=false

# 终端 3 - DAIB-Explorer
source ~/catkin_ws/devel/setup.bash && roslaunch daib_explorer explorer.launch

# 终端 4 - Ego-Planner (bridge + planner + traj_server)
source ~/catkin_ws/devel/setup.bash && roslaunch ego_planner daib_single_uav.launch
```

### 主机端 (ros1-rviz 容器)

```bash
docker start ros1-rviz
xhost +local:docker
```

进容器：

```bash
docker exec -it ros1-rviz bash
```

容器内终端：

```bash
# 终端 1 - PX4 SITL + Gazebo
cd ~/XTDrone/sitl_config/launch
roslaunch px4 outdoor_my.launch

# 终端 2 - XTDrone 手动控制基线专用；自动轨迹控制时不要启动
cd ~/XTDrone/communication
python3 multirotor_communication.py iris 0

# 终端 3 - 键盘控制
cd ~/XTDrone/control/keyboard
python3 multirotor_keyboard_control.py iris 1 vel

# 终端 4 - rviz 可视化
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0
source /opt/ros/noetic/setup.bash
rviz -d ~/fast_livo2.rviz

```

## 传感器话题映射

| 传感器 | Gazebo Topic | FAST-LIVO2 期望 |
|--------|-------------|-----------------|
| Livox Avia | `/scan` (CustomMsg) | `/livox/lidar` |
| Realsense IMU | `/iris_0/imu_gazebo` | `/livox/imu` |
| 左目相机 | `/iris_0/stereo_camera/left/image_raw` | `/left_camera/image` |

avia.yaml 当前配置的仿真话题：`/scan`, `/iris_0/imu_gazebo`, `/iris_0/stereo_camera/left/image_raw`


## rviz 显示

- Fixed Frame: `camera_init`
- **TF** — 坐标系
- **PointCloud2** `/cloud_registered` — SLAM 实时点云
- **Marker** `/drone_0_ego_planner_node/optimal_list` — 规划轨迹
- **Marker** `/drone_0_ego_planner_node/goal_point` — 探索目标点
- **PointCloud2** `/drone_0_ego_planner_node/grid_map/occupancy_inflate` — 局部栅格
- **Path** `/path` — SLAM 里程计轨迹



```
roslaunch ego_planner daib_manual.launch \
traj_server_pose_cmd_topic:=/xtdrone/iris_0/cmd_pose_enu \
max_vel:=0.3 \
max_acc:=0.5

```
