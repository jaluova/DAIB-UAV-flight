# DAIB-Planner 大疆无 GPS 实机安全修改交接（给 YYY 仓库 Agent）

日期：2026-08-10

本文是一份可独立执行的实现说明。接手 Agent 不应假设自己了解此前聊天、板端测试、
两个远端的分支关系或 PX4 实验背景。

## 1. 任务目标

在 YYY 当前 `DAIB-Planner` 主线基础上，补齐大疆无 GPS 实机链路需要的运行时安全、
目标生命周期和诊断能力。

本任务不是增加新的局部规划算法。EGO 的 B-spline、碰撞检测和轨迹优化继续保留。
主要解决以下实际风险：

1. odom 或规划点云丢失后，活跃轨迹仍可能继续执行；
2. 当前急停状态依赖未可靠初始化的隐式标志，可能进入 `EMERGENCY_STOP` 却没有发布
   停止轨迹；
3. 首次规划和重规划失败会无限重试，Explorer 不知道目标在 Planner 层不可达；
4. 当前按“规划轨迹时间结束”判断到达，没有确认无人机真实 odom 已到目标；
5. 偏航速度写死为约 `180 deg/s`，且初始 yaw 固定为 0，不适合大疆实机；
6. Bridge 的“已接受 generation”只表示已转发，不表示已生成有效轨迹；
7. 当前日志无法快速区分目标被 Bridge 拒绝、地图未就绪、优化失败、轨迹阻塞或输入
   watchdog 触发。

目标状态应形成以下闭环：

```text
Explorer goal
    -> Bridge 原子化为 goal + generation
    -> EGO 接受并尝试规划
    -> ACTIVE / REACHED / BLOCKED / EMERGENCY_STOP
    -> 反馈同一个 generation
```

Planner 不负责选择下一个 frontier。Planner 只报告当前 generation 的真实结果，目标
选择和失败目标冷却仍由 Explorer 负责。

## 2. 仓库与基线

Planner 路径：

```text
src/DAIB-Planner
```

远端：

```text
origin   = https://github.com/YYY0702/ego-planner-swarmYYY.git
jaluova  = https://github.com/jaluova/DAIB-Planner.git
```

双方共同基线：

```text
cf9784f6cc42650160d009b061948d8cf7485512
feat: refresh smooth active trajectories from current state
```

YYY 当前主线：

```text
e6f50a6e999cde8a6215eddaa30689b3949675a9
Merge pull request #3 from jaluova/sync-yyy-main-build-fixes
```

该提交在共同基线上只增加 B-spline `const` 正确性编译修复 `fde7470`，没有新的
Planner 算法。

可参考但不能整体 cherry-pick 的 jaluova 提交：

```text
0a33e3c  feat: plan with fresh IMU-rate odometry
157f67a  fix: restore XTDrone pose output from trajectory server
81f29da  fix: improve DAIB planning diagnostics
0cfaffb  feat: add reliable PX4-local planning safety
696bbe1  feat: add observation-aware global maps
```

建议从 YYY 当前主线建立独立分支：

```bash
git fetch origin
git switch -c agent/planner-dji-runtime-safety origin/main
```

不要整体 cherry-pick `0a33e3c..696bbe1`。这些提交混有 PX4、XTDrone 和另一套地图
坐标域。应按本文要求手工移植通用部分。

## 3. 必须保持的运行接口

当前实机为大疆无人机，Orange Pi 5 Max，Ubuntu 22.04，用户名 `orangepi`，任务走
无 GPS 路线。Planner 必须继续使用以下接口：

```text
里程计：    /daib_slam/odom                 nav_msgs/Odometry
规划点云：  /daib_explorer/planning_cloud  sensor_msgs/PointCloud2
世界坐标系：camera_init
目标输入：  /daib_explorer/goal
目标代次：  /daib_explorer/generation
轨迹输出：  /daib_ego/position_cmd
```

禁止在本任务中引入或改成：

```text
/daib_slam/imu_odom
PX4 map 坐标系
/daib_px4/planning_cloud
planning_cloud_px4_bridge
px4_odom_camera_init.py
XTDrone /pose_cmd
daib_global_map
```

当前 DAIB-LIVO 源码没有发布 `/daib_slam/imu_odom`。如果直接采用 `0a33e3c` 的默认
launch，Planner 会一直等待不存在的 odom。

不要修改 LIVO、Explorer、Docker、DJI 控制适配器或飞控协议。可以新增 Planner 的
状态输出接口，但不得让 Planner 编译依赖 Explorer 源码。

## 4. 保留的现有能力

以下能力已经在共同基线中，应保留：

- Explorer 到 EGO 的 Bridge 和 ready/odom/goal 基本校验；
- generation 去重；
- `camera_init` frame 检查；
- 独立占据点云接入 EGO grid map；
- B-spline 动力学约束、障碍膨胀和局部碰撞检查；
- 首次规划尝试次数和失败重试 backoff；
- 正常重规划优先延续当前 B-spline 的位置、速度、加速度；
- 跟踪误差超过阈值时，从真实 odom 重新锚定轨迹；
- 活跃 B-spline 的 10 Hz 平滑可视化；
- 轨迹完成后 `traj_server` 持续输出终点零速度命令的 hold 行为；
- 空点云作为有效 heartbeat，同时保留此前保守障碍地图的语义；
- B-spline `const` 编译修复 `fde7470`。

不得通过降低障碍膨胀、关闭 cloud watchdog 或放宽目标边界来掩盖规划失败。

## 5. P0：修复急停状态机

### 5.1 当前缺陷

当前 `ego_replan_fsm.cpp` 使用 `flag_escape_emergency_` 决定是否调用
`callEmergencyStop()`：

```text
进入 EMERGENCY_STOP
    -> flag_escape_emergency_ 为真：发布停止轨迹
    -> 否则：可能只停留在状态机中
```

YYY 当前主线没有在 `init()` 中可靠初始化该 bool。首次 `SEQUENTIAL_START` 成功后也
没有建立清晰的“可以发布急停”状态；部分碰撞分支进入 `EMERGENCY_STOP` 前没有设置该
标志。因此存在未定义行为和漏发停止轨迹风险。

### 5.2 修改要求

删除 `flag_escape_emergency_` 及其所有隐式语义，改成明确字段：

```text
fault_latched
emergency_stop_published
last_valid_odom_position
fault_reason
```

实现统一入口，例如：

```cpp
void latchPlanningFault(const std::string& reason);
```

行为必须为：

1. 第一次进入故障闭锁时保存 `last_valid_odom_position`；
2. 清除 active target 和待重规划状态；
3. 只调用一次 `callEmergencyStop(last_valid_odom_position)`；
4. 发布 `EMERGENCY_STOP` 状态及当前 generation；
5. 后续 timer 回调不得离开 `EMERGENCY_STOP`；
6. 新目标不得解除故障；当前版本用重启 Planner 作为人工确认；
7. 重复 fault 不得重复生成大量停止 B-spline 或刷日志。

启动阶段从未收到过有效 odom/cloud 时只进入 `WAIT_INPUT`，不能立即闭锁。只有在输入
曾经有效、Planner 已 armed 后丢失输入，才触发运行期故障闭锁。

注意：停止 B-spline 只能表达 Planner 期望。它不能替代 DJI 控制适配器的命令超时、
控制权检查和飞控悬停保护。不要在文档或日志中声称 Planner 单独保证了飞行安全。

## 6. P0：odom 合法性与超时保护

参考 `0a33e3c` 的通用逻辑，但保持 `/daib_slam/odom`。

### 6.1 合法性

每条 odom 在写入状态前检查：

- position x/y/z 全部有限；
- linear velocity x/y/z 全部有限；
- quaternion x/y/z/w 全部有限；
- quaternion norm 大于小阈值，归一化后再使用；
- `header.frame_id == camera_init`。

非法样本不得覆盖最后有效状态。用 throttle 日志报告，由“最后一次有效 odom 的接收
墙钟时间”驱动 watchdog。单个坏样本不需要立即闭锁；持续没有有效样本最终由超时
触发。

### 6.2 新鲜度

新增参数：

```xml
<arg name="odom_timeout_s" default="0.5"/>
<param name="fsm/odom_timeout_s" value="$(arg odom_timeout_s)"/>
```

必须使用 `ros::WallTime` 判断消息是否持续到达，不能把 bag `/clock`、传感器 epoch 和
系统墙钟混在一起。消息时间戳仍用于 goal/odom 同一传感器时间域的新旧关系判断。

行为：

```text
从未收到有效 odom       -> WAIT_INPUT
收到有效 odom 后暂时无目标 -> WAIT_TARGET
活跃或正在规划时 odom 超时 -> latchPlanningFault("ODOM_TIMEOUT")
```

不要把默认 odom 改成 `/daib_slam/imu_odom`。

## 7. P0：规划点云就绪与超时保护

当前 `GridMap::hasDepthObservation()` 已能判断独立点云是否到达，frame 检查和空点云
heartbeat 语义也已存在。需要把它真正纳入目标接收和状态机门控。

要求：

1. 在第一帧有效规划点云到达前，不接受目标进入 EGO 规划，状态为 `WAIT_INPUT`；
2. 点云 `frame_id` 非空且不是 `camera_init` 时拒绝；
3. 空点云仍是有效 heartbeat，不清空旧的保守地图；
4. 有效点云曾到达、轨迹已 active 后，持续超过 `cloud_timeout_s` 才闭锁；
5. 启动时尚无点云不得触发急停；
6. 默认 `cloud_timeout_s: 1.0`，实机测试确认稳定频率后再收紧；
7. watchdog 使用墙钟接收时间，不使用 bag 时间戳；
8. cloud timeout 和 odom timeout 都走第 5 节的统一故障入口。

`0cfaffb` 中依赖 `/daib_px4/planning_input_valid` 的部分不能直接移植。把安全闭锁做成
通用 Planner 内部输入健康状态，不依赖 PX4 topic。

## 8. P0：目标 generation 与规划结果闭环

### 8.1 当前问题

`/daib_ego/accepted_generation` 当前只表示 Bridge 已转发目标。Bridge 在 EGO 真正规划
之前就发布 accepted，首次局部轨迹可能随后失败。EGO 失败时只按 0.2 s backoff 无限
重试，Explorer 无法判断该目标在 Planner 的膨胀地图或动力学约束下不可达。

另外，内部 goal 和 generation 目前是两个独立 ROS topic，依靠接收时间窗口配对。
目标快速更新、latched topic 重连或 callback 调度改变时，存在 generation 与 goal
错配风险。

### 8.2 推荐的原子内部消息

在 `daib_ego_bridge` 中新增消息，名称可按仓库规范调整，但语义必须等价：

```text
# GoalCommand.msg
uint64 generation
geometry_msgs/PoseStamped goal
```

Bridge 仍接收现有 Explorer topics，但完成校验和 generation 配对后，只向 EGO 发布一条
原子的 `GoalCommand`。新 topic 建议为：

```text
/daib_ego/goal_command
```

EGO 改为订阅该新 topic，不再通过两个 callback 猜测目标代次。现有
`/daib_ego/goal` 的 `PoseStamped` 输出至少在过渡期继续保留，供现有手动测试、诊断和
旧 launch 使用；不得在同名 topic 上直接更换 ROS 消息类型。

Bridge 不应在 source generation 尚未匹配时自行递增并伪造 generation。正常运行等待
Explorer 的显式 generation；只有明确启用 legacy/manual 模式时才允许生成本地代次，
并在状态 reason 中标记 `LEGACY_GENERATION`。

新增状态消息：

```text
# GoalStatus.msg
uint8 ACCEPTED=0
uint8 ACTIVE=1
uint8 REACHED=2
uint8 BLOCKED=3
uint8 EMERGENCY_STOP=4

std_msgs/Header header
uint64 generation
uint8 status
string reason
geometry_msgs/Point goal
float64 distance_to_goal
uint32 consecutive_planning_failures
```

建议输出：

```text
/daib_ego/goal_status
```

状态含义：

- `ACCEPTED`：目标通过输入校验并被 FSM 接受，但还没有有效局部轨迹；
- `ACTIVE`：至少一条针对该 generation 的有效 B-spline 已发布；
- `REACHED`：真实 odom 满足到达条件；
- `BLOCKED`：该 generation 达到有界规划失败条件，要求 Explorer 换目标；
- `EMERGENCY_STOP`：运行输入或近端碰撞触发故障停止。

只接受严格递增的 generation。相同 generation 的重复消息幂等忽略；更小 generation
拒绝并记录 `OUT_OF_ORDER_GENERATION`。新 generation 清零旧目标的失败计数和到达确认
状态。

如本轮不修改 Explorer，可先完成状态发布和 rostest；Explorer 消费 `BLOCKED` 的修改
作为下一步提交。不得为了避免消息定义而继续使用无关联的 String 和 UInt64 topic。

## 9. P0：规划失败必须有界

当前 initial planning 和 replanning 都可能永久循环。新增参数：

```yaml
max_initial_plan_failures: 5
max_replan_failure_duration_s: 3.0
replan_failure_backoff_s: 0.2
```

要求：

### 9.1 首次轨迹失败

```text
ACCEPTED
  -> 尝试生成局部轨迹
  -> 成功：ACTIVE
  -> 连续失败达到 max_initial_plan_failures：BLOCKED
```

进入 `BLOCKED` 时发布一次明确停止/hold 轨迹，清除当前 active target，等待 Explorer
提供更大的 generation。不要自动重新接受同一个 generation。

### 9.2 活跃轨迹重规划失败

- 旧轨迹未来段仍安全时，可以继续旧轨迹并按 backoff 重试；
- 失败持续超过 `max_replan_failure_duration_s`，报告 `BLOCKED`；
- 若检测到碰撞且距离碰撞小于 `emergency_time`，直接 `EMERGENCY_STOP`；
- 不允许在旧轨迹已经结束后仍永久停留在 `REPLAN_TRAJ`；
- 每个新 generation 单独统计失败次数和首次失败墙钟时间。

Planner 报告 `BLOCKED` 后不自行挑选目标。Explorer 应把失败目标短期排除后发布新
generation。

## 10. P0：用真实 odom 判断到达

当前 FSM 在 B-spline 时间播放完毕后直接清除 `have_target_`。这只是“计划执行时间
结束”，不代表无人机实际到达。

新增参数：

```yaml
goal_reached_distance_m: 0.8
goal_reached_speed_mps: 0.3
goal_reached_confirm_s: 0.5
```

到达条件：

```text
distance(odom_position, goal) <= goal_reached_distance_m
AND norm(odom_velocity) <= goal_reached_speed_mps
AND 条件连续保持 goal_reached_confirm_s
```

只有满足该条件才发布 `REACHED` 并进入 `WAIT_TARGET`。B-spline duration 到期但真实
odom 仍偏远时：

1. 保持当前 generation；
2. 从最新 odom 尝试重新规划或维持终点 hold；
3. 若有界重规划持续失败，发布 `BLOCKED`；
4. 不得仅因出现更好的新候选自行换目标，换点由 Explorer 的新 generation 驱动。

这项修改必须和 Explorer 的持久目标策略一起工作，否则双方会对“目标是否完成”产生
不同理解。

## 11. P1：偏航限制和初始 yaw

当前 `traj_server.cpp` 使用固定 `PI rad/s` 最大偏航速度，并把 `last_yaw_` 初始化为
0。若实机启动朝向不是 0，第一条轨迹可能产生不必要的大转向。

参考 `0cfaffb`，新增：

```xml
<param name="traj_server/max_yaw_rate" value="0.35"/>
```

要求：

1. 默认 `max_yaw_rate = 0.35 rad/s`，参数非法时回退该值；
2. 所有 wrap-around 分支统一使用该参数，不再使用固定 `PI`；
3. `traj_server` 订阅同一个 `/daib_slam/odom`，从有效四元数初始化 `last_yaw_`；
4. 第一帧命令不得假设 yaw 为 0；
5. `dt <= 0`、时间回退或过大 timer 间隔时不得产生除零、NaN 或一步大跳；
6. 保留基于未来轨迹切线计算期望 yaw 的思路；
7. 不添加 XTDrone `/pose_cmd`。

Explorer 已限制目标转向，Planner yaw rate limit 是第二道执行约束，两者职责不同。

## 12. P1：轨迹消息与输出数值校验

`traj_server` 当前默认信任 B-spline 消息，并直接按数组大小构造轨迹。增加输入校验：

- order 合法；
- control point 数量满足阶数要求；
- knot 数量合法且单调；
- 所有 control point 和 knot 有限；
- `start_time`、计算出的 duration 有效；
- 求值后的 position/velocity/acceleration/yaw/yaw_dot 全部有限。

非法轨迹不得发布 `TRAJECTORY_STATUS_READY`。记录 throttle error，并通过 Planner 状态
报告故障。不要让空数组、坏 knot 或 NaN 进入 DJI 适配器。

轨迹正常结束后继续发布终点零速度 hold 可以保留。但如果 `traj_server` 或整个容器
退出，必须依赖外部 DJI adapter 的独立 command watchdog；本任务不伪造这一能力。

## 13. P1：目标边界保持保守

Bridge 当前 YYY 配置为：

```yaml
min_goal_distance_m: 0.5
max_goal_distance_m: 20.0
min_goal_z_m: -2.5
max_goal_z_m: 4.5
```

根据实机经验和 Explorer 策略，将 Planner 最终防线改为：

```yaml
min_goal_distance_m: 0.5
max_goal_distance_m: 8.0
min_goal_z_m: -2.5
max_goal_z_m: 4.5
```

Explorer 正常应发布约 `1.5~8.0 m` 目标，Bridge 的较小 min 只作为协议容差。

绝对不要复制 `81f29da` 中临时放宽到 `100 m`、`-5~25 m` 的参数。可以复制它的拒绝
原因日志，但必须保留本节边界。

## 14. P1：诊断日志

参考 `81f29da`，但统一为节流、单行和可检索格式。重要事件至少包含：

```text
generation
FSM state
goal xyz
distance_to_goal
odom_age_wall_s
cloud_age_wall_s
initial/replan failure count
trajectory_id
reason
```

推荐状态原因：

```text
WAIT_ODOM
WAIT_CLOUD
REJECT_FRAME
REJECT_BOUNDS
REJECT_STALE
REJECT_DISTANCE
OUT_OF_ORDER_GENERATION
INITIAL_PLAN_FAILED
REPLAN_FAILED
TRAJECTORY_COLLISION
ODOM_TIMEOUT
CLOUD_TIMEOUT
GOAL_REACHED
```

删除或降低以下噪声：

- 100 Hz/1 Hz 重复的 `Triggered!`、`no odom!`；
- 带 ANSI 颜色的大段 stdout；
- 每次失败都打印整套优化器中间状态；
- 把未优化控制多边形显示成成功轨迹。

`81f29da` 中两项通用诊断修复值得手工移植：

1. 独立点云模式的 occupancy 可视化从 inflated buffer 发布，避免诊断 topic 永远空；
2. 优化失败时不把未优化 control points 显示为“最优轨迹”。

不要连同该提交的宽松飞行边界一起移植。

## 15. 建议修改文件

主要修改范围：

```text
src/planner/plan_manage/include/plan_manage/ego_replan_fsm.h
src/planner/plan_manage/src/ego_replan_fsm.cpp
src/planner/plan_manage/src/traj_server.cpp
src/planner/plan_manage/launch/daib_single_uav.launch
src/planner/plan_manage/CMakeLists.txt
src/planner/plan_manage/package.xml

src/planner/daib_ego_bridge/src/daib_ego_bridge_node.cpp
src/planner/daib_ego_bridge/config/bridge.yaml
src/planner/daib_ego_bridge/msg/GoalCommand.msg
src/planner/daib_ego_bridge/msg/GoalStatus.msg
src/planner/daib_ego_bridge/CMakeLists.txt
src/planner/daib_ego_bridge/package.xml

src/planner/plan_env/src/grid_map.cpp
```

建议把纯状态逻辑拆成不依赖 ROS timer 的小类，例如：

```text
PlanningSafetyLatch
GoalExecutionTracker
```

只在它们能显著简化测试时增加，不要重构 EGO 优化器、A* 或 B-spline 数学实现。

## 16. 测试要求

### 16.1 单元测试

至少覆盖：

1. 启动时没有输入只等待，不闭锁；
2. 输入曾有效后 odom timeout，闭锁且只领取一次 emergency stop 发布权；
3. cloud timeout 走同一个闭锁入口；
4. 非有限 odom 不覆盖最后有效状态；
5. generation 相同幂等，更小拒绝，更大重置计数；
6. initial planning 失败达到上限后变为 `BLOCKED`；
7. B-spline 时间结束但 odom 离目标较远时不能 `REACHED`；
8. 距离和速度连续满足确认时间后才 `REACHED`；
9. yaw 跨 `-pi/pi` 时走最短方向且不超过 rate limit；
10. 非法 B-spline 数组、非单调 knot 和 NaN 被拒绝。

### 16.2 ROS runtime test

至少覆盖：

1. 无 odom/cloud 时目标不进入规划；
2. odom + 首帧 cloud 到达后目标进入 `ACCEPTED`；
3. 有效轨迹发布后状态为 `ACTIVE` 且 generation 一致；
4. 模拟不可规划目标，达到有界失败条件后发布同 generation 的 `BLOCKED`；
5. active 后停止 odom，发布一次 `EMERGENCY_STOP` 和一次 stop B-spline；
6. active 后停止 cloud，行为同上；
7. 轨迹 duration 结束但 odom 不跟随时不能报告 `REACHED`；
8. 新 generation 到达后旧 generation 的延迟状态不得覆盖新状态；
9. `use_sim_time=true` 和 bag epoch 与墙钟不同的情况下，目标新鲜度判断仍正确。

### 16.3 构建与板端验证

先在正常构建环境运行测试，再验证 ARM64：

```bash
catkin_make -DCMAKE_BUILD_TYPE=Release -j1
catkin_make run_tests
catkin_test_results
```

板端用真实 bag 验证时至少记录：

```text
/daib_slam/odom hz
/daib_explorer/planning_cloud hz
/daib_explorer/goal
/daib_explorer/generation
/daib_ego/goal_status
/drone_0_planning/bspline
/daib_ego/position_cmd
```

bag 是开环数据，录制 odom 不会跟随新生成的 position command。因此 bag 验证可以检查
接口、规划、watchdog、generation 和数值有限性，但不能用来证明真实闭环跟踪或到达。

## 17. 建议提交拆分

按以下顺序提交，便于审查和回退：

```text
1. fix: make planner emergency stop deterministic
2. feat: validate and watchdog DAIB planning inputs
3. feat: report generation-aware goal execution status
4. fix: determine goal completion from measured odometry
5. feat: bound yaw rate and validate trajectory commands
6. fix: improve DAIB planner diagnostics
7. test: cover DAIB planner runtime safety contract
```

不要把所有修改压成一个大提交，也不要 force-push YYY 主线。

## 18. 完成标准

满足以下条件才算完成：

- 默认接口仍为 `/daib_slam/odom`、`/daib_explorer/planning_cloud`、`camera_init`；
- 不包含 PX4、XTDrone 或另一套全局地图依赖；
- 急停不再依赖 `flag_escape_emergency_`；
- odom/cloud 启动等待与运行期丢失行为可区分；
- 每次故障闭锁只发布一次停止轨迹；
- 规划失败有界，并携带正确 generation 报告 `BLOCKED`；
- 只有真实 odom 到达才报告 `REACHED`；
- yaw 初始化来自真实 odom，偏航速度可配置并默认不超过 `0.35 rad/s`；
- Bridge 最大目标距离为 `8.0 m`，没有复制 100 m/25 m 临时边界；
- 非法 odom、B-spline 或非有限 command 不会进入输出；
- 单元测试、rostest、Release 构建和 ARM64 `-j1` 构建通过；
- 对现有 Explorer、LIVO 和 `/daib_ego/position_cmd` 外部接口无意外破坏。
