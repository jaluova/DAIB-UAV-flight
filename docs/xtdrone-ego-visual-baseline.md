# XTDrone EGO 低速可视化基线

日期：2026-08-01

## 用途

该流程用于人工观察和复测 XTDrone 官方低速链路：

```text
GPS/PX4 local odometry -> EGO-Planner -> 官方 traj_server
-> /xtdrone/iris_0/cmd_pose_enu -> multirotor_communication.py
-> MAVROS/PX4
```

约束：单机 `iris_0`、目标高度 `1.0 m`、`max_vel=0.5 m/s`、
`max_acc=1.0 m/s^2`。测试期间不得启动其他 MAVROS setpoint 发布者。

## 启动

在主机终端执行：

```bash
cd /home/ufd/cc-chat
./scripts/xtdrone_ego_visual.sh start
```

脚本启动 Gazebo、RViz、PX4 SITL、MAVROS、XTDrone communication、
`ego_transfer.py`、EGO-Planner 和官方 `traj_server`。它会等待以下条件成立后
才报告成功：

- MAVROS `connected=True`；
- 深度图已经发布；
- communication 节点存活；
- MAVROS local setpoint 流已经建立；
- EGO-Planner 与 RViz 已启动。

此时飞机仍为 `armed=False`。

### Enhanced communication（仅速度控制可选）

如需复测键盘或其他 `cmd_vel_flu/cmd_vel_enu` 输入的单轴位置保持，可显式
选择 enhanced 脚本：

```bash
XTDRONE_COMMUNICATION_SCRIPT=multirotor_communication_enhanced.py \
  ./scripts/xtdrone_ego_visual.sh start
```

不要把它与阶段 B 的 geometric controller 同时启动。enhanced 的保持逻辑只在
`cmd_vel_*` 回调中生效；本页 EGO 链使用 `cmd_pose_enu`，与原版生成相同的纯
位置 setpoint，因此替换后不会改善 EGO 的速度前馈或 tracking error。原版仍为
默认值，以保持本页已记录基线及其 FCU 检查和 PX4 参数行为不变。

## 起飞和目标

起飞到 1 m：

```bash
./scripts/xtdrone_ego_visual.sh takeoff
```

等待输出显示 `armed: True`、`mode: OFFBOARD`，并在 Gazebo 中确认稳定悬停。

发送目标有两种方式：

1. 在 RViz 顶部选择 `2D Nav Goal`，点击附近空闲位置。
2. 使用命令发送，例如前进 2 m：

```bash
./scripts/xtdrone_ego_visual.sh goal 2 0
```

该 XTDrone 官方 EGO 回调会把 RViz 目标高度固定为 `1.0 m`。建议先测试
1-2 m 的短距离目标，不要直接点击地图边界或障碍物内部。

RViz 专用配置显示：

- Realsense 深度图；
- EGO 膨胀占据图；
- 目标点与优化轨迹；
- PX4 local odometry 的实际位置和历史姿态。

## 状态和日志

```bash
./scripts/xtdrone_ego_visual.sh status
./scripts/xtdrone_ego_visual.sh logs
```

检查重点：

- `connected=True`、`armed=True`、`mode=OFFBOARD`；
- 起飞后高度接近 1 m；
- RViz 出现目标点和优化轨迹；
- Gazebo 中实际运动方向与 RViz 轨迹一致；
- 到点后速度回落并保持悬停。

## 正确退出

必须先降落，再停止后台进程：

```bash
./scripts/xtdrone_ego_visual.sh land
# 确认 armed: False
./scripts/xtdrone_ego_visual.sh stop
```

不要把关闭 Gazebo/RViz 窗口当成停止测试。窗口关闭后，PX4、Gazebo server、
EGO 和 communication 仍可能在后台运行，飞机甚至可能保持解锁和 OFFBOARD。
`stop` 检测到 `armed=True` 时会拒绝关闭控制进程。

## 重启和冲突

正常重启：

```bash
./scripts/xtdrone_ego_visual.sh start
```

若报告 `Conflicting ROS or control processes`：

```bash
./scripts/xtdrone_ego_visual.sh status
```

- 若 `armed=False`，执行 `stop` 后再 `start`。
- 若 `armed=True`，先执行 `land`，确认上锁后再执行 `stop` 和 `start`。
- 若模型已经倾倒、弹跳且 `AUTO.LAND` 无法上锁，不要直接关闭后台控制源；
  该情况需要按 SITL 异常处理，确认强制停桨后再清理。

## 相关文件

- `scripts/xtdrone_ego_visual.sh`：可视化生命周期和飞行命令。
- `scripts/xtdrone_ego_low_speed.launch`：低速 EGO 与 `traj_server`。
- `scripts/xtdrone_ego_low_speed.rviz`：单机专用 RViz 配置。
- `scripts/analyze_xtdrone_baseline_bag.py`：rosbag 指标分析。
- `docs/ego-px4-control-architecture.md`：控制架构与分阶段验收。
