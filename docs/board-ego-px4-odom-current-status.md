# 板端 EGO + PX4 odom 当前状态

日期：2026-08-01

## 当前目标

先恢复并保留以下自动控制对照链路：

```text
板端 EGO-Planner
  odom: /iris_0/mavros/local_position/odom
  pose output: /xtdrone/iris_0/cmd_pose_enu
        -> XTDrone communication
        -> /iris_0/mavros/setpoint_raw/local
        -> PX4
```

该阶段先验证板端 EGO 的规划和自动飞行效果。SLAM 点云避障暂不作为验收项，
也暂不切换 PX4 到无 GPS 状态估计。

## 正确启动命令

板端 `ros1_dev` 容器内：

```bash
source ~/catkin_ws/devel/setup.bash

roslaunch ego_planner daib_manual.launch \
  odom_topic:=/iris_0/mavros/local_position/odom \
  traj_server_pose_cmd_topic:=/xtdrone/iris_0/cmd_pose_enu \
  max_vel:=0.3 \
  max_acc:=0.5
```

本轮不要增加 `world_frame:=map`，不要启动 `pose_frame_bridge.py`。

启动后检查：

```bash
rostopic info /xtdrone/iris_0/cmd_pose_enu
rostopic info /iris_0/mavros/setpoint_raw/local
```

预期：

- `/xtdrone/iris_0/cmd_pose_enu` 的发布者是 `/drone_0_traj_server`；
- `/xtdrone/iris_0/cmd_pose_enu` 的订阅者是 `/iris_0_communication`；
- `/iris_0/mavros/setpoint_raw/local` 只有 `/iris_0_communication` 一个发布者。

## 三条链路的区别

### 1. 板端 EGO 仅规划显示

```bash
roslaunch ego_planner daib_manual.launch
```

默认使用 `/daib_slam/odom` 和 `/daib_slam/planning_cloud`。`traj_server` 的 Pose
输出被接到 `/daib_ego/pose_cmd_unused`，因此 RViz 可以显示规划，但不会自动
控制飞机。飞机若运动，通常来自键盘控制。

### 2. 板端 EGO + PX4 odom 自动控制

使用本文“正确启动命令”。EGO 用 PX4 local odom 规划，Pose 直接交给 XTDrone
communication，因此可以点击目标后自动飞行。这是当前希望恢复和继续观察的
状态。

### 3. 本机官方 XTDrone EGO 基线

```bash
XTDRONE_COMMUNICATION_SCRIPT=multirotor_communication_enhanced.py \
  ./scripts/xtdrone_ego_visual.sh start
```

该链路的 EGO 在本机 `ros1-rviz:/root/xtdrone_ego_ws` 中运行，使用 PX4 odom、
Realsense depth 和官方 XTDrone launch。它曾完成稳定的 1 m 起飞和约 2 m 目标，
但不是当前所说的“板端运行 EGO”。

## 已知点云与 Marker 问题

板端自动控制模式存在 frame 不一致：

```text
PX4 odom: map
SLAM planning cloud: camera_init
daib_manual 默认 world_frame: camera_init
```

直接设置 `world_frame:=map` 会导致 EGO 明确拒绝输入：

```text
Reject grid-map cloud frame 'camera_init'; expected 'map'.
Reject goal in frame 'camera_init'; expected 'map'.
```

因此当前不能靠修改一个 launch 参数同时修正 PX4 odom、SLAM 点云、Marker 和
目标。若以后恢复避障，需要先将 `/daib_slam/planning_cloud` 正确转换到 PX4
`map`，再让 EGO 使用 `world_frame:=map`。

在完成点云转换前：

- 自动控制可作为短距离、空旷区域测试；
- 红色 Marker 和 SLAM 点云的相对显示可能错位；
- 不得据此判断避障有效；
- 不靠近障碍物测试。

## 实验性 Pose 转换桥

已创建 `scripts/pose_frame_bridge.py`，用于另一种架构：EGO 保持使用 SLAM odom
和 SLAM 点云，只在输出端将 Pose 转到 PX4 local frame。

该桥不是当前“板端 EGO + PX4 odom”对照测试所需组件，当前不要启动。每次
FAST-LIVO2 重启后 `camera_init` 可能变化，旧校准也不能复用。

## 最近状态

为消除多套 ROS master 和控制节点冲突，最近一次操作已在确认
`armed=False` 后关闭本机官方 XTDrone 基线及其 PX4、MAVROS、Gazebo、RViz、
communication 和 EGO 进程。继续测试前应按实际选择的一条链路从头启动，不能
混合运行板端 EGO、本机官方 EGO、Pose 转换桥或多个 keyboard 节点。

## 安全退出

任何链路都必须先降落并确认：

```text
armed: False
```

随后再停止 EGO、communication、PX4、Gazebo 或 roscore。关闭 RViz/Gazebo
窗口不等于停止后台控制节点。
