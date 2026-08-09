# IMU 高频里程计与 10 Hz 点云规划部署

日期：2026-08-02

## 本提交边界

本提交只建立 FAST-LIVO2 到 EGO-Planner 的无 GPS 规划接口：

```text
FAST-LIVO2 雷达校正（约 10 Hz）
  -> 每条 IMU 顺序传播
  -> /daib_slam/imu_odom（camera_init -> aft_mapped）
  -> EGO FSM 和 GridMap

/daib_slam/planning_cloud（约 10 Hz，camera_init）
  -> EGO GridMap
```

PX4 外部视觉注入、`camera_init` 到 PX4 local frame 的完整
`PositionCommand` 变换和飞控侧 watchdog 不在本提交中。在完成这些工作前，
不得把本提交单独视为可起飞的无 GPS 闭环。

## 运行契约

- 高频 odom 和规划点云的 `header.frame_id` 必须都是 `camera_init`。
- 高频 odom 使用对应 IMU 样本的传感器时间戳，不能用发布时刻代替。
- 每次 LIO 更新后，高频传播必须从校正后的状态重新开始。
- IMU 单步间隔超过 `0.05 s` 时停止传播，等待下一次 LIO 校正。
- EGO 超过 `0.3 s` 未收到 odom 时发布紧急停止轨迹，并要求重启规划器。
- EGO 超过 `0.5 s` 未收到点云心跳时进入点云丢失保护。
- 空点云仍是合法心跳，表示当前 bounded planning cloud 内没有占用点。

## 板端启动

FAST-LIVO2 的 `config/avia.yaml` 已默认启用 `/daib_slam/imu_odom`。先启动
FAST-LIVO2，再确认接口：

```bash
rostopic hz /daib_slam/imu_odom
rostopic hz /daib_slam/planning_cloud
rostopic echo -n 1 /daib_slam/imu_odom/header
rostopic echo -n 1 /daib_slam/planning_cloud/header
```

手动同高度目标：

```bash
roslaunch ego_planner daib_manual.launch
```

手动三维目标：

```bash
roslaunch ego_planner daib_manual.launch manual_goal_use_message_z:=true
python3 scripts/send_goal.py 3 0 1.5
```

标准 RViz `2D Nav Goal` 通常发布 `z=0`，所以手动 launch 默认忽略消息 z 并
保持当前高度。自主模式使用 DAIB-Explorer 的真实三维目标：

```bash
roslaunch ego_planner daib_single_uav.launch
```

## 上板前检查

```bash
python3 scripts/test_imu_planning_contract.py
```

录制至少以下话题，并验证 30 秒静止、升降和水平运动：

```text
/livox/imu
/daib_slam/odom
/daib_slam/imu_odom
/daib_slam/planning_cloud
/daib_ego/position_cmd
```

验收时检查 odom 频率、最大周期、`receipt-header` 延迟、相邻位置和速度跳变，
并主动停止 IMU 和点云输入，分别验证 `0.3 s` 与 `0.5 s` watchdog。
