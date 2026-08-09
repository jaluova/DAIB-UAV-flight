# FAST-LIVO2 + EGO-Planner + PX4 控制架构决策

日期：2026-08-01

## 目标

完成以下闭环，而不是只在 RViz 中生成轨迹：

```text
FAST-LIVO2 -> DAIB-Explorer -> EGO-Planner -> trajectory controller -> MAVROS/PX4
```

FAST-LIVO2 负责定位和建图，DAIB-Explorer 负责探索目标，EGO-Planner
负责碰撞检查与动态可行 B 样条。`/daib_ego/position_cmd` 是规划器与飞行
控制器之间的边界。

## 已确认事实

### XTDrone 官方示例

XTDrone 的 `run_in_xtdrone.launch` 将 EGO `traj_server` 的 `/pose_cmd`
直接映射到 `/xtdrone/iris_0/cmd_pose_enu`。随后
`multirotor_communication.py` 发布 MAVROS `PositionTarget`，但 mask 掉速度和
加速度，只保留位置与 yaw。

这个示例是三维运动规划和低速位置跟踪基线，不是完整的 frontier 自主探索
系统，也不是高质量动态轨迹跟踪器。它适合验证 PX4、MAVROS、坐标系和基础
OFFBOARD 链路，不作为最终控制架构。

参考：

- https://github.com/robin-shaun/XTDrone/blob/master/motion_planning/3d/ego_planner/plan_manage/launch/run_in_xtdrone.launch
- https://github.com/robin-shaun/XTDrone/blob/master/communication/multirotor_communication.py

### 当前执行层失败原因

EGO `PositionCommand` 包含 position、velocity、acceleration、yaw 和 yaw rate。
将它降级为 Pose 会丢失速度与加速度前馈。若再叠加运行时坐标估计、步长
裁剪、tracking gate 和超时保持，实际送给 PX4 的轨迹已经不再是 EGO 生成的
动态轨迹，故障边界也变得无法判定。

另一个已确认问题是 RViz `2D Nav Goal` 通常携带 `z=0`。三维飞行中必须由
真正的 3D 目标源提供高度，或明确保持当前高度，不能无条件采用该 z 值。

### 可复用项目

LIO-Drone-250 与当前需求最接近：FAST-LIO2 + EGO-Planner +
`geometric_controller` + MAVROS/PX4。其控制器直接订阅
`quadrotor_msgs/PositionCommand`，使用 position、velocity、acceleration 和
yaw，并提供起飞、悬停、OFFBOARD 与失效状态。

它基于成熟的 `mavros_controllers`。`px4_fast_planner` 也采用
Fast-Planner + `mavros_controllers`，验证了相同的规划器/控制器边界。

参考：

- https://github.com/zjz0001/LIO-Drone-250
- https://github.com/Jaeyoung-Lim/mavros_controllers
- https://github.com/mzahana/px4_fast_planner
- https://docs.px4.io/main/en/flight_modes/offboard

## 决策

1. 保留 FAST-LIVO2、DAIB-Explorer、EGO-Planner 和 `traj_server`。
2. 不再使用任何 `PositionCommand -> Pose -> XTDrone` 自研执行链。
3. 官方 XTDrone Pose 链只用于独立、低速基线测试。
4. 最终执行层优先评估 LIO-Drone-250 的 `geometric_controller`，直接消费
   `/daib_ego/position_cmd`。
5. 自主控制时必须只有一个 MAVROS setpoint 发布者；不能同时运行 XTDrone
   communication、键盘控制和轨迹控制器。
6. 规划器和控制器反馈必须处于同一坐标系，并使用一致的状态估计。
7. GPS/PX4 local-position 控制基线通过后，才单独切换 FAST-LIVO2 外部视觉
   融合；不得同时调试控制器和无 GPS EKF。
8. 固定 3D 目标闭环稳定后，才接回 DAIB-Explorer 连续目标。

## 分阶段验收

### A. XTDrone 官方基线

- GPS/Gazebo 定位。
- 官方 EGO 示例和固定 3D 目标。
- 最大速度 0.5 m/s，最大加速度 1.0 m/s^2。
- 验证起飞、跟踪、悬停和停止，不接 FAST-LIVO2 或 Explorer。

#### 2026-08-01 实测结果

使用 `PX4 outdoor_my.launch`、单机 `iris_0` 和 GPS/PX4 local odometry，闭环为：

```text
PX4 local odom -> XTDrone EGO-Planner -> 官方 traj_server
-> /xtdrone/iris_0/cmd_pose_enu -> multirotor_communication.py
-> /iris_0/mavros/setpoint_raw/local -> PX4
```

测试 launch 为 `scripts/xtdrone_ego_low_speed.launch`，参数为
`max_vel=0.5 m/s`、`max_acc=1.0 m/s^2`、`flight_type=1` 和
`traj_server/time_forward=1.0 s`。未启动 FAST-LIVO2、DAIB-Explorer 或其他
自研控制节点。MAVROS setpoint 只有官方 `iris_0_communication` 一个发布者。

官方源码在 `ros1-rviz:/root/xtdrone_ego_ws` 独立构建。完整工作区会因无关的
`drone_detect` 缺少 `roslint` 而失败；实际使用以下白名单成功构建：

```bash
catkin_make \
  -DCATKIN_WHITELIST_PACKAGES="quadrotor_msgs;plan_env;path_searching;traj_utils;bspline_opt;ego_planner" \
  -DCMAKE_BUILD_TYPE=Release -j2
```

输入与状态：

- MAVROS connected，GPS、global position 和 local odometry 正常。
- Realsense 深度图约 20 Hz，`/iris_0/camera_pose` 约 60 Hz，规划 odometry 约 30 Hz。
- 解锁前 raw local setpoint 约 30 Hz，`type_mask=2552`，即官方纯位置+yaw控制。
- 完成解锁、OFFBOARD、1 m 起飞、约 2 m 同高度目标、悬停和 `AUTO.LAND` 自动上锁。
- EGO 成功生成 4 条 B 样条消息，包含初始规划和 3 次重规划，最终回到
  `WAIT_TARGET`。

rosbag 统计：

| 指标 | mean | p95 | max |
|---|---:|---:|---:|
| 实际三维速度 | 0.0704 m/s | 0.1601 m/s | 0.4982 m/s |
| `PositionCommand` 三维速度 | 0.0207 m/s | 0.1682 m/s | 0.5607 m/s |
| Pose setpoint 跟踪误差 | 0.0728 m | 0.1667 m | 0.5684 m |

目标为 `(1.97, 0.02, 1.0)`，记录结束位置为
`(1.9547, 0.0471, 1.0113)`，终点误差 `0.0331 m`。实际速度峰值满足
0.5 m/s 基线，但官方 `PositionCommand` 瞬时峰值超过配置上限约 12%。
Pose 跟踪误差还包含 `time_forward=1.0 s` 的主动前瞻，不能解释为纯控制误差。
到点后一次较晚的单点观测出现高度约 `1.088 m`、速度约 `0.101 m/s`，说明
官方 Pose 链可作为低速连通基线，但不应升级为最终轨迹执行器。

复测 rosbag 可使用 `scripts/analyze_xtdrone_baseline_bag.py` 分析。
人工可视化复测步骤见 `docs/xtdrone-ego-visual-baseline.md`。

### B. 成熟控制器基线

下一步优先完成该阶段，不同时接入 FAST-LIVO2 或 Explorer：

1. 以 LIO-Drone-250 的 `geometric_controller` 和上游
   `mavros_controllers` 为候选，确认 ROS Noetic、PX4 1.13、MAVROS 话题和
   `quadrotor_msgs/PositionCommand` 接口兼容性。
2. 暂不启动 EGO，使用 GPS/PX4 local odometry，让控制器独立完成解锁、
   OFFBOARD、1 m 起飞、定点悬停、超时保护和降落。
3. 停止 XTDrone communication，确保新控制器是唯一 MAVROS setpoint 发布者。
4. 将官方 `traj_server` 的 `PositionCommand` 直接接入控制器，保留 position、
   velocity、acceleration、yaw 和 yaw rate，不再降级为 Pose。
5. 重复本阶段相同的 2 m 固定目标和 rosbag 统计，再逐级测试
   0.5/1.0、1.0/2.0 m/s 与 m/s^2 限制。

#### 2026-08-01 兼容性与编译结果

已在 `ros1-rviz`（Ubuntu 20.04、ROS Noetic、MAVROS 1.20.1）建立独立
`/root/lio_controller_ws`，固定 LIO-Drone-250 提交 `a0614d5`。仅构建
`controller_msgs` 和 `geometric_controller`，不构建或启动 FAST-LIO、EGO
和 Explorer。补齐 catkin 直接依赖后，Release 编译通过。

LIO 仓库自带 `PositionCommand` 比当前 EGO 消息多一个 `jerk` 字段，ROS1
MD5 不兼容。独立工作区因此不暴露 LIO 的 `quadrotor_msgs`，而是复用
`/root/xtdrone_ego_ws` 的版本；实测 MD5 为
`4712f0609ca29a79af79a35ca3e3967a`，可直接连接当前 EGO 输出。

当前结论仅为“编译与消息接口兼容”，尚未批准起飞。LIO fork 原样代码缺少
生效的 PositionCommand 超时保护，两个服务回调缺少返回值，且起飞/悬停使用
MAVROS position setpoint、轨迹阶段改用 raw attitude setpoint。必须先完成安全
补丁和无桨/仿真状态机测试，再进入 1 m 起飞验收。完整记录和复现命令见
`docs/lio-controller-noetic-compatibility.md`。

阶段 B 的最低验收条件：

- 起飞和 30 s 定点悬停不退出 OFFBOARD；
- 只有一个 MAVROS setpoint 发布者；
- 命令中断后进入明确的悬停或降落状态；
- 固定目标飞行无明显姿态翻转、触地或持续振荡；
- 实际速度、终点误差和 tracking error 不劣于阶段 A，并保存 rosbag 结果。

### C. FAST-LIVO2 状态闭环

- 验证 odometry 时间戳、坐标轴、原点、速度和跳变。
- 将 FAST-LIVO2 状态稳定提供给 PX4/控制器，确保规划与控制使用同一状态。
- 再进行固定目标飞行，不启动 Explorer。

2026-08-01 首轮 GPS/EKF 对比表明，FAST-LIVO2 的低频位置一致性已经达到
约 5 cm mean、10 cm p95 水平误差，但实时输出只有约 15 Hz，并存在明显周期
抖动和到达延迟。位置 frame 与 quaternion yaw 还需要分别校准。详细数据与
下一轮录制方案见 `docs/slam-gps-odom-comparison-20260801.md`。

### D. 自主探索

- 恢复 DAIB-Explorer。
- 验证目标新鲜度、占据云 watchdog、EGO 重规划连续性和紧急停止。
- 最后进行连续 frontier 目标和完整任务测试。

## 安全边界

任一阶段未通过时不得进入下一阶段。控制测试必须记录至少：

```text
/daib_slam/odom
/iris_0/mavros/local_position/odom
/daib_ego/position_cmd
/iris_0/mavros/setpoint_raw/local 或控制器等价输出
/iris_0/mavros/state
```

评价依据是频率与抖动、位置/速度/加速度连续性、p95/max tracking error、
OFFBOARD 状态和命令超时行为，不以 RViz 曲线观感代替闭环数据。
