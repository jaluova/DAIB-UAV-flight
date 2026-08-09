# FAST-LIVO2 Gazebo 仿真环境

## 概述

在主机 (Ubuntu 20.04 x86_64, NVIDIA GPU) Docker 容器中运行 Gazebo 11 仿真，
模拟 Livox Avia LiDAR + IMU + RGB Camera 传感器，
通过网络 ROS 通信连接 Atlas 200I DK A2 开发板上的 FAST-LIVO2 SLAM 节点。

## 架构

```
主机 (192.168.0.101)                      开发板 (192.168.0.2)
┌──────────────────────────────┐          ┌──────────────────────────────┐
│ ros1-gazebo 容器             │          │ ros1_dev 容器                 │
│ --net=host                   │          │ roscore :11311               │
│ ROS_MASTER_URI→192.168.0.2   │          │                              │
│                              │  TCP     │ fastlivo_mapping              │
│ Gazebo 11                    │          │  订阅:                       │
│   slam_robot (SDF)           │          │    /livox/lidar (CustomMsg)  │
│   ├─ Avia LiDAR ─────────────┼──────────┼─▶  /livox/imu                │
│   ├─ IMU ────────────────────┼──────────┼─▶  /left_camera/image        │
│   └─ Camera ─────────────────┼──────────┼─▶                          │
│                              │          │  发布:                       │
│ rviz (NVIDIA GPU) ◄──────────┼──────────┼── /cloud_registered          │
│                              │          │    /tf /path                 │
└──────────────────────────────┘          └──────────────────────────────┘
```

## 镜像: ros1-gazebo:latest

基于 `ros1-rviz:latest` 扩展构建。

### 构建过程

```bash
# 1. 启动 ros1-rviz 容器
docker run -it --name ros1-gazebo-tmp --net=host \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  ros1-rviz:latest bash

# 2. 安装 Gazebo 11 + ROS-Gazebo 桥接
#    需先修复 ROS apt 源: packages.ros.org + GPG key
apt update && apt install -y \
  gazebo11 ros-noetic-gazebo-ros-pkgs ros-noetic-gazebo-plugins \
  ros-noetic-gazebo-ros-control ros-noetic-robot-state-publisher \
  ros-noetic-joint-state-publisher-gui ros-noetic-xacro \
  ros-noetic-image-transport ros-noetic-image-transport-plugins \
  git cmake build-essential ros-noetic-cmake-modules libpcl-dev ros-noetic-pcl-ros

# 3. 验证
gazebo --version

# 4. 退出并 commit
exit
docker commit ros1-gazebo-tmp ros1-gazebo:latest
docker rm ros1-gazebo-tmp
```

### 现有镜像状态

镜像 `ros1-gazebo:latest` 已构建完成，容器 `ros1-gazebo-tmp` 中包含：
- `/root/sim_ws/` — 仿真 catkin workspace (已编译)
- Gazebo 11.15.1 + ROS Noetic gazebo_ros_pkgs
- Mid360_simulation_plugin (Livox LiDAR 仿真插件，支持 CustomMsg)
- simulation_robot 包 (SDF 模型 + launch 文件)

## Workspace 结构

```
/root/sim_ws/
├── src/
│   ├── livox_laser_simulation/          # Livox LiDAR 仿真插件
│   │   └── livox_laser_simulation/
│   │       ├── src/
│   │       │   ├── livox_points_plugin.cpp    # Livox 点云仿真插件
│   │       │   └── livox_ode_multiray_shape.cpp
│   │       ├── scan_mode/                     # LiDAR 扫描模式 CSV
│   │       │   ├── avia.csv
│   │       │   ├── mid360-real-centr.csv
│   │       │   ├── mid40.csv
│   │       │   └── ...
│   │       ├── launch/test_pattern.launch     # 测试 launch
│   │       ├── models/sensors_only/model.sdf  # 纯 LiDAR 测试模型
│   │       └── worlds/test_pattern.world
│   └── simulation_robot/                # 我们的仿真机器人
│       ├── launch/
│       │   └── slam_sim.launch           # 主启动文件
│       ├── models/slam_robot/
│       │   ├── model.sdf                 # 机器人 SDF 模型 (LiDAR+IMU+Camera)
│       │   ├── model_min.sdf             # 极简版 (LiDAR only, 调试用)
│       │   └── model.config
│       └── worlds/
│           └── indoor.world              # 室内场景
└── devel/lib/
    └── liblivox_laser_simulation.so      # 编译好的 Livox 插件
```

## 插件说明: Mid360_simulation_plugin

- **来源**: https://github.com/fratopa/Mid360_simulation_plugin (199 stars)
- **适配**: Gazebo 11 + ROS Noetic + Ubuntu 20.04
- **特点**: 独立运行，不需要 Livox SDK/ROS Driver
- **支持**: CustomMsg (publish_pointcloud_type=3), PointCloud2, PointCloud
- **支持型号**: Avia, Mid-360, Mid-40, Mid-70, Horizon, Tele

### 关键参数

| 参数 | 说明 | 我们的值 |
|------|------|---------|
| `ros_topic` | 发布的话题名 | `/livox/lidar` |
| `csv_file_name` | 扫描模式 CSV | `avia.csv` |
| `publish_pointcloud_type` | 0=PointCloud, 1=PointCloud2 XYZ, 2=PointCloud2 Livox, **3=CustomMsg** | `3` |
| `samples` | 每帧采样点数 | `24000` (Avia) |
| `downsample` | 降采样因子 | `1` |
| `frameName` | 发布的 frame_id | `livox_link` |

### 避坑记录

#### 老插件 (Livox_simulation_customMsg) 不兼容 Gazebo 11

老插件 `Luchuanzhao/Livox_simulation_customMsg` 是为 Gazebo 7/9 + Ubuntu 18.04 写的：

| 问题 | 现象 | 解决 |
|------|------|------|
| `#include <gazebo-7/...>` | 编译失败 | 改为 gazebo-9 |
| `libprotobuf.so.9` | 链接失败 | 改为 libprotobuf.so.17 |
| `ros::init()` 在 `gazebo_ros` 后再次调用 | gzserver 段错误 | 加 `if(!ros::isInitialized())` |
| Gazebo 11 API 变化 | 编译/运行时崩溃 | 改用 Mid360_simulation_plugin |

#### IMU 插件类型

| 插件文件 | 类型 | 加载位置 |
|---------|------|---------|
| `libgazebo_ros_imu.so` | **Model** 插件 | `<model>` 级别下 |
| `libgazebo_ros_imu_sensor.so` | **Sensor** 插件 | `<sensor>` 内部 |

在 SDF 的 `<sensor>` 内必须用 `libgazebo_ros_imu_sensor.so`，否则 Gazebo 报
`incorrect plugin type` 然后段错误。

#### URDF → SDF 转换

`spawn_model -urdf` 会自动把 URDF 转成 SDF，但可能丢失/损坏插件参数。
Livox 仿真插件是为 SDF 设计的，**推荐直接用 SDF 格式写模型**。

## 启动流程

### 前置条件

1. 开发板 roscore 运行中
2. 本机与开发板双向 hostname 解析:
   ```bash
   # 本机
   echo "192.168.0.2 davinci-mini" | sudo tee -a /etc/hosts
   # 开发板
   echo "192.168.0.101 $(hostname)" >> /etc/hosts
   ```

### 启动仿真

```bash
# 启动容器
docker start ros1-gazebo-tmp
docker exec -it ros1-gazebo-tmp bash

# 容器内
echo "192.168.0.2 davinci-mini" >> /etc/hosts
source /opt/ros/noetic/setup.bash
source /root/sim_ws/devel/setup.bash
export ROS_MASTER_URI=http://192.168.0.2:11311

# headless 模式 (无 GUI)
roslaunch simulation_robot slam_sim.launch

# GUI 模式
roslaunch simulation_robot slam_sim.launch gui:=true headless:=false
```

### 启动 rviz 可视化

```bash
# 另开终端进同一容器
docker exec -it ros1-gazebo-tmp bash
echo "192.168.0.2 davinci-mini" >> /etc/hosts
export ROS_MASTER_URI=http://192.168.0.2:11311
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0
rviz
```

### 独立测试 (不连开发板)

```bash
# 在容器内
pkill -9 gzserver rosmaster 2>/dev/null
export ROS_MASTER_URI=http://localhost:11311
roscore &
sleep 3
source /root/sim_ws/devel/setup.bash
roslaunch simulation_robot slam_sim.launch
```

## 传感器 Topic 对照

| 传感器 | Gazebo Topic | 消息类型 | FAST-LIVO2 期望 |
|--------|-------------|---------|----------------|
| Livox Avia | `/livox/lidar` | `livox_ros_driver/CustomMsg` | ✅ 匹配 |
| IMU | `/livox/imu` | `sensor_msgs/Imu` | ✅ 匹配 |
| RGB Camera | `/left_camera/image` | `sensor_msgs/Image` | ✅ 匹配 |
| Ground Truth | `/ground_truth/odom` | `nav_msgs/Odometry` | 评测用 |

## GUI 模式

需要 X11 转发 + NVIDIA GPU 加速:

```bash
# 本机
xhost +local:docker

# 容器内
export DISPLAY=:1        # 或 :0，看你的环境
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0
```

## PX4 + XTDrone 仿真传感器布局

基于 `iris_realsense_livox` SDF 模型的传感器安装位置（base_link 坐标系，单位: 米）。

```
                     前 (X+)
                      ↑
                      |
       ┌──────────────┼──────────────┐
       │  Livox Avia  │              │
       │  (0.05,0,0.095)  Realsense  │
       │              │  Camera      │
       │              │  (0.10,0,0)  │
       │              │  + IMU       │
       │              │  (0.10,0,0.30)│
       │                              │
   左 ←─── base_link (0,0,0) ───→ 右 (Y+)
       │                              │
       │  PX4 IMU     左相机          │
       │  (/imu_link)  (0.10,0.06,0)  │
       │              右相机          │
       │              (0.10,-0.06,0)  │
       └──────────────────────────────┘
                      ↓
                     下 (Z-)
```

### 传感器安装位置

| 传感器 | X (前) | Y (左) | Z (上) | Topic / Frame |
|--------|--------|--------|--------|---------------|
| Livox Avia LiDAR | 0.05 m | 0 | 0.095 m | `/scan` (CustomMsg), frame: `laser_livox` |
| Realsense IMU | 0.10 m | 0 | 0.30 m | `/iris_0/imu_gazebo`, frame: `imu_link_stereo` |
| 左目相机 | 0.10 m | 0.06 m | 0 | `/iris_0/stereo_camera/left/image_raw` |
| 右目相机 | 0.10 m | -0.06 m | 0 | `/iris_0/stereo_camera/right/image_raw` |
| PX4 IMU | ~0 | ~0 | ~0 | `/iris_0/imu`, frame: `/imu_link` |
| GPS | 0.10 m | 0 | 0 | `/iris_0/mavros/global_position/global` |

### 传感器外参

**LiDAR → Realsense IMU:**

```
T_LiDAR_IMU = [-0.05, 0, -0.205]
R = I (单位阵)
```

**LiDAR → 左相机:**

```
T_LiDAR_Camera = [-0.05, -0.06, 0.095]
R = I
```

### Realsense 相机内参

| 参数 | 值 |
|------|-----|
| 模型 | Pinhole |
| 分辨率 | 752 × 480 |
| fx | 375.9986 |
| fy | 375.9986 |
| cx | 376.0 |
| cy | 240.0 |
| k1 | -0.1 |
| k2 | 0.01 |
| p1 | 0.00005 |
| p2 | -0.0001 |

### Livox Avia LiDAR 参数

| 参数 | 值 |
|------|-----|
| 视场角 | 70.4° (H) × 77.2° (V) |
| 扫描频率 | 10 Hz |
| 消息类型 | `livox_ros_driver/CustomMsg` |
| 每帧点数 | ~3000 |
| 测距范围 | 0.1 — 200 m |

### 实物部署时的外参一致性

仿真中的 `extrinsic_T` / `Rcl` / `Pcl` 是理想安装值，实物部署后必须重新标定。

仿真 `avia.yaml` 已按照模型中的相对安装位置填入，如果实物安装不同，需要对比仿真与实物的差异重新标定。

## 已知限制

| 限制 | 说明 | 影响 |
|------|------|------|
| Camera 无画面 | headless 模式 Gazebo 无渲染引擎 | GUI 模式正常 |
| Livox Avia 扫描模式 | 插件发布 Mid360 模式数据的用 avia.csv 重排 | 扫描角度有差异但不影响 SLAM |
| 无 robot control | 目前是静态基座，没配控制器 | 机器人不能移动 |
| 开发板性能 | 3.4GB RAM 跑 FastLIVO2 可能丢帧 | 调低 LiDAR 采样率或用更简单场景 |
