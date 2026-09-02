# 系统验证方案（分层验收）

- 文档版本：2026-09-01
- 适用对象：现场实施 / 交付验收 / 测试人员
- 对应基线：`sync_yyy`（`CURRENT_SYNC_YYY_BASELINE.md`），部署见
  [domestic-deployment-guide-20260901.md](domestic-deployment-guide-20260901.md)

## 1. 目的与验证总原则

本方案把"系统验证"组织为**分层验收**，每一层有明确的通过/判定标准，逐层通过后才
进入下一层。总原则（来自基线文档）：

1. 使用真实 MID-70、D435i 和 IMU，不默认播放 bag；
2. roscore、驱动、Foxglove 与算法容器保持独立生命周期；
3. 先单独验证 SLAM，再验证 Explorer，之后才启动 Planner；
4. 每次只改变一个模块或一组明确参数，并记录镜像 ID、命令和 ROS 参数值；
5. Explorer 基线测试关闭 PVBSM scoring 与动态预算；
6. 旧文档与当前镜像/当前提交冲突时，以当前镜像内文件和基线提交为准。

验证层次总览：

```text
L0 环境与传感器自检（时钟、频率、时间戳）
 L1 SLAM 层（接口契约、实时性、地图精度）
  L2 Explorer 层（目标语义、行为验收、计算隔离）
   L3 Planner/适配层（bridge 合约、转换、干跑）
    L4 PSDK 控制链路地面联调（UDP 校验、权限状态机）
     L5 实飞验证（分阶段门禁，当前为待验证状态）
```

## 2. L0 环境与传感器自检

### 2.1 前置

按部署指南完成部署并启动：

```bash
cd /mnt/huawei_ssd/daib
./scripts/start_lio_only.sh --check-seconds 15
```

### 2.2 自检内容

- **时钟**：板端无硬件 RTC；脚本执行 chrony/NTP 检查，不可用时恢复最近已知正确时钟并输出告警。
- **传感器时序**：`deploy/scripts/check_sensor_timing.py --validate`，阈值表：

| 检查项 | 阈值 |
|---|---|
| LiDAR 频率 | 8.0–12.0 Hz |
| LiDAR 每帧点数（中位数） | ≥ 9000 |
| LiDAR 扫描周期（中位数） | 80–120 ms |
| LiDAR 扫描结束到达滞后（中位数） | −20..80 ms |
| IMU 频率 | 150–260 Hz |
| IMU 到达-时间戳滞后（中位数） | −20..80 ms |
| IMU 最近邻 LiDAR 时间差 p95 | ≤ 10 ms |
| 图像频率（默认） | 25–35 Hz |
| 图像到达-时间戳滞后（中位数） | −20..120 ms |
| 图像最近邻 LiDAR 时间差 p95 | ≤ 25 ms |
| 时间戳回退 | 0 次 |

- **启动门**：脚本输出 `[PASS] LIO-only stack is ready` 才进入下一层。
  LIVO/飞行栈模式对应输出 `normal LIVO mode`、`[PASS] Flight stack is ready`；
  观察模式输出 `[7/7] Playback + Explorer/EGO observation ready`。

## 3. L1 SLAM 层

### 3.1 接口契约（SLAM → Explorer 数据面）

```bash
rostopic hz /daib_slam/odom
rostopic hz /daib_slam/planning_cloud
rostopic echo -n 1 /daib_slam/odom/header
rostopic echo -n 1 /daib_slam/planning_cloud/header
```

判定（详见 `src/DAIB-Explorer/docs/RUNTIME_VALIDATION.md` §1）：

- odom 与 planning_cloud 非空，接近 LIO 频率持续更新；
- 两者 frame 均为 `camera_init`；
- 对应时间戳差 ≤ 0.2 s（正常完全相同）；
- `/daib_explorer/ready` 在两类输入到达后变 `true`，输入停止后按
  `input_timeout_s` 变回 `false`。

> PVBSM 相关校验项（`/daib_slam/pvbsm_delta` 约 1 Hz、payload ≤ 32 KiB 等）
> 仅在启用 PVBSM 时适用；当前基线默认以 `pvbsm_memory_enabled:=false
> pvbsm_scoring_enabled:=false` 启动，不强制。

### 3.2 SLAM 实时性

```bash
./scripts/measure_livo_hz.sh
```

统计 FAST-LIVO 单帧处理时间（LIO 全帧与 VIO 行），给出平均/峰值/P95/最小值并可换算
可达 Hz：帧预算 100 ms（对标 10 Hz）内通过，持续超预算判定为算力不足。

### 3.3 地图精度测量（≤ 5 cm 判定）

流程（详见 [measure-map-accuracy-5cm.md](measure-map-accuracy-5cm.md)）：

1. 现场放置已知长度参照物（20–50 cm 短参照 + ≥ 1 m 长参照，长度用硬尺量准）；
2. 香橙派录制：

   ```bash
   ./scripts/record_map_accuracy.sh 90
   ```

   动作建议：静止起飞 → 缓慢完整扫两遍标定物 → 降落；确认无 `.bag.active` 再断电；
3. 传输到本机：

   ```bash
   rsync -avP --partial <OP用户>@<OP_IP>:/mnt/ssd/bags/map_acc_*.bag ~/DAIB-UAV-flight/bags/
   ```
4. 导出 PCD 并测量：

   ```bash
   /tmp/o3d-venv/bin/python tools/bag_to_pcd.py bags/map_acc_xxx.bag /cloud_registered acc.pcd --accumulate
   /tmp/o3d-venv/bin/python tools/measure_pcd_distances.py acc.pcd --expected 0.20 1.00 ...
   ```

判定表：

| 现象 | 结论 |
|---|---|
| 各项误差 ≤ 5 cm，符号不随参照长度持续同号 | 通过（局部几何 + 尺度 OK） |
| 误差随参照长度近似线性增长（1 m 差 1 cm、2 m 差 2 cm） | 地图尺度偏差，按百分比报告 |
| 短参照误差大、长参照误差小 | 局部点云抖动/密度问题，非尺度问题 |

无真实 bag 时可用 `tools/make_test_bag.py` + `tools/test_board.pcd` 回归整条
录包→导出→测量链路。

## 4. L2 Explorer 层

### 4.1 行为验收（判定条目）

依据 `src/DAIB-Explorer/docs/RUNTIME_VALIDATION.md` §2，结合当前基线配置
（`allow_periodic_goal_switch=false`、`goal_timeout_s=0`、stall 15 s）：

- free / occupied / frontier / visited 计数增长，日志的 `cycles` 比例接近
  10 map : 10 blocked-check : 2 frontier : 1 goal : 1 memory 每秒；
- 合法 goal：frame 为 `camera_init`，与当前高度差 ≤ `max_goal_vertical_distance_m`，
  尽量停在 frontier cluster 内；每个发布 goal 距离 ≤ 8 m、相对当前 yaw ≤ 120°；
- goal 在到达/持续阻塞/stall 前，generation 保持不变的语义（
  `allow_periodic_goal_switch=false`）；单次瞬时占用更新不切换目标；
  持续阻塞按 `goal_blocked_confirm_updates` 次确认后切换；
- ≥ 15 s 无进展（`goal_progress_epsilon_m`）触发替换；被替换的失败目标在
  `failed_goal_exclusion_radius_m` 内、`failed_goal_cooldown_s` 内不可再选；
- 每个有效 goal 位于已知 free 体素，且与 occupied 体素中心距离 ≥
  `min_wall_clearance_m`；
- 预算日志显示 `budgets=128 rays/2048 frontier`；板端负载超阈值时动态预算应
  自动降低探索工作量。

### 4.2 验收必须覆盖的场景（基线文档 2026-08-12 节）

1. 来源 cluster 消失且没有新候选 —— goal 必须撤销/停止执行，不能保留旧目标；
2. cluster 消失但有替代候选 —— 正常切换；
3. cluster 暂时抖动 —— 不误切目标；
4. Bridge 已转发旧 goal —— 撤销后停止执行。

### 4.3 观察模式与 watchdog

```bash
./scripts/start_explorer_planning_observe.sh --check-seconds 15 --camera-rate 8
```

- 该模式启动 Explorer + `daib_ego_bridge` + EGO-Planner + `traj_server`，但把
  PositionCommand 隔离到 `/daib_observe/position_cmd_unconnected`，脚本确认该话题
  无订阅者后才显示 `[PASS]`；不启动任何飞控/SDK；
- 观察模式 watchdog（`scripts/daib_planning_watchdog.sh`）：Explorer 单独异常只重启
  Explorer，EGO 单独异常只重启 EGO，两级恢复失败才重启两者；恢复时重发 latched goal；
  两级都失败输出 `FAIL planning recovery failed; keep manual control and return`，
  此时保持遥控并人工返航；
- EGO 点云超时默认 3 s（`EGO_CLOUD_TIMEOUT_S`）；普通 `plan_success=0` 或 A* 无路
  不算故障，不可达目标由 Explorer 15 s 停滞策略负责更换。

### 4.4 自动契约测试（可选回归）

- `src/DAIB-Explorer/test/runtime_contract_test.py`（rostest）：合成 odom/cloud，
  断言 ready→true、goal/frontier/cluster 的 frame+stamp、输入失效后 ready→false；
- `src/DAIB-Explorer/test/explorer_core_test.cpp`：核心逻辑单元测试。

### 4.5 计算隔离（算力回归）

同一 bag 三种配置各跑一轮：仅 FAST-LIVO2 / + 空闲 Explorer / + 活跃 Explorer，
记录 LIO 平均/P95/P99 延迟、CPU、RSS 与可达频率。过程中杀死 Explorer 再重启：
`/daib_slam/odom` 等 SLAM 输出必须持续，Explorer 能无重启 SLAM 重建滚动地图。

## 5. L3 Planner / 适配层

### 5.1 Bridge 合约

`daib_ego_bridge`（`src/DAIB-Planner`）：goals 的 frame/generation 门禁、
陈旧目标拒绝、`accepted_generation` 语义；0.2 s 同步、1.0 s 门禁阈值见
`src/DAIB-Planner/docs/DAIB_INTEGRATION.md`。对应 rostest：
`src/DAIB-Planner/src/planner/daib_ego_bridge/test/runtime_contract_test.py`。

### 5.2 适配器转换单元测试

```bash
g++ -std=c++14 -I src/DAIB-Planner/src/planner/psdk_velocity_adapter/include \
  src/DAIB-Planner/src/planner/psdk_velocity_adapter/test/velocity_adapter_test.cpp \
  -o /tmp/velocity_adapter_test
/tmp/velocity_adapter_test
```

覆盖：坐标变换（`odom_child_optical:=true` 的 FRU 轴映射）、限幅（默认
0.5/0.2 m/s、yaw 3 deg/s）、200 ms 无更新输出全零。

### 5.3 Planner 链路干跑

流程见 [planner-adapter-dry-run-20260824.md](planner-adapter-dry-run-20260824.md)。
启动顺序：FAST-LIVO（传感器静止 5 s）→ EGO 先订阅 → Explorer → adapter。
检查：

- `/daib_ego/position_cmd` 有发布者，velocity/yaw_dot 随 B-spline 连续变化；
- `/psdk/velocity_command` 约 20 Hz；`linear.x/y/z` 不超 `0.5/0.5/0.2 m/s`；
  yaw 角速度不超限幅；planner 停止更新 0.2 s 后输出归零；
- 全程无 PSDK 日志、无权限获取、无飞机动作。

**通过**：odom 持续、目标被 bridge 接受、B-spline/PositionCommand 持续、adapter
持续发布、速度和 yaw 均被限幅、停止后归零、全程无飞机动作。
**暂停并记录**（任一）：odom 无数据或时间戳不前进、planner 进入 `EMERGENCY_STOP`
或持续 `plan_success=0`、`/daib_ego/position_cmd` 无发布者、adapter 持续无效但
planner 明确有效、超限或停止后不归零、节点崩溃或连续通信错误。

边界声明：干跑只证明 传感器→SLAM→Planner→B-spline→PositionCommand→转换层；
**不能证明飞机会跟随，不能证明坐标轴已完成实机标定**。

## 6. L4 PSDK 控制链路地面联调

完整流程见 [psdk-udp-bridge-test-procedure-20260826.md](psdk-udp-bridge-test-procedure-20260826.md)
（链路：Orange Pi adapter → UDP 19090 → Manifold PSDK bridge → DJI
ExecuteJoystickAction；限幅 0.1/0.05/0 m/s）。阶段门禁：

1. **网络检查**：ping / `nc -uvz <Manifold> 19090` / `ip route get`，确认流量走正确网卡；
2. **Python dry-run**：`tools/psdk_velocity_udp_receiver.py` 连续收包、序号递增、
   数值在限幅内；停发后约 200 ms 出现 `NEUTRAL reason=timeout`；
3. **C++ bridge 编译与启动**：`[100%] Built target dji_sdk_demo_on_manifold3_cxx`，
   进入 `u` 菜单；bridge 默认只接收校验，不调用运动 API；
4. **权限状态机**：`M → ACTIVE → U → IDLE` 正常；RC 切模式/Pause 触发
   `ABORTED` 且自动解除输出；
5. **接入 DJI API 地面验证**：`L + M` 后 20 Hz 调用 `ExecuteJoystickAction()`，
   无持续错误；停发后约 200 ms 中性归零（`U` 先解除 live output 再释放控制权）。

**§9 通过标准**（全部满足才算链路通过）：

- Python dry-run 连续收包、停发 200 ms 中性归零；
- C++ bridge 启动并监听 19090；
- `M → ACTIVE → U → IDLE` 正常；
- RC 夺权触发 `ABORTED` 且输出自动解除；
- `L + M` 时 DJI API 无持续错误，超时使用中性指令；
- 任何异常可通过 `U` 或 RC 夺权停止输出。

未满足全部条件前，不进入自主规划器直接控制飞行测试。

## 7. L5 实飞验证（当前状态：待验证）

实飞按 [psdk-test-roadmap.md](psdk-test-roadmap.md) 分阶段门禁推进：

```text
j（低速控制演示）→ k → m → n → p → t → planner_adapter
```

每个阶段通过并记录后才能进入下一阶段；`planner_adapter` 阶段只有在 L3 干跑与 L4
地面联调全部通过后才有资格执行。

**重要状态声明**：截至本方案发布（2026-09-01），PSDK/M400 相关飞行测试文档普遍
标注"尚未完成实机验证"，本方案的 L5 层对应阶段为**待验证**状态。交付验收时 L5 的
每一项必须给出实飞记录与结果，未完成项不得标记为通过。

实飞安全约束（来自 PSDK 地面测试手册）：任何方向异常、通信异常、权限无法释放或
日志持续报错，立即按 `U`，必要时飞手切 RC；程序不会自动起飞、降落或解锁电机。

## 8. 录包与回放规范

### 8.1 完整探索流程录包

按 [exploration-run-recording-plan.md](exploration-run-recording-plan.md)：

- **A 层（实际结果，必录）**：`/daib_slam/odom`、`/path`、`/cloud_registered`、
  `/daib_explorer/goal`、`/daib_explorer/selected_cluster_frontiers`、
  `/drone_0_ego_planner_node/goal_point`、`/drone_0_ego_planner_node/optimal_list`、
  `/daib_ego/position_cmd`、`/psdk/dji_command_xyz_yaw`；
- **B 层（原始输入，建议录）**：`/livox/lidar`、`/camera/imu`、
  `/camera/color/image_fast_livo`（约 10 Hz；30 Hz 的 `image_raw` 仅在排查时加）；
- 推荐档位：A 层全量 + B 层三项，`/cloud_registered` 限频 2–5 Hz，
  LZ4 压缩、4 GiB 分卷；`rosbag record --lz4 --split --size=4096`；
- 结束必须等待 `[PASS] Recording finalized`，禁止存在 `.bag.active` 时断电；
- 每次录制旁保存元数据文件：起止时间（含时区）、两端地址、镜像标签、git 提交、
  话题列表与限频、速度/yaw 限制、是否启用 DJI API 输出；
- 回放原则：只展示实飞结果就回放 A 层；要重算算法行为必须停止实时驱动、以 B 层
  输入回放并另存为新 bag，标注"重算轨迹"，不得覆盖原实飞包。

### 8.2 传感器输入录包（复盘用）

```bash
./scripts/record_fast_livo_inputs.sh --min-free-gb 20
```

只录 FAST-LIVO 输入（`/livox/lidar`、`/camera/imu`、10 Hz 图像），不足以保存完整
探索结果，适合传感器问题复盘；`--include-raw-image` 额外加 30 Hz 原图（包体明显增大）。

## 9. 验收记录要求

每次验证（无论通过与否）至少记录：

```text
镜像标签 + image ID（不能只写 openeuler-arm64）
启动命令与 ROS 参数值（如 vio_img_point_cov、各 limit）
实际话题列表与频率测量值
bash 脚本输出的 [PASS]/[FAIL] 行
通过/判定表对应的实测数值
```

## 10. 参考文档

- [CURRENT_SYNC_YYY_BASELINE.md](CURRENT_SYNC_YYY_BASELINE.md) —— 基线、分层测试原则、验收必覆盖场景
- [flight-quickstart-README.md](flight-quickstart-README.md) —— 启动/观察/录包/回放入口
- `src/DAIB-Explorer/docs/RUNTIME_VALIDATION.md` —— Explorer 接口契约与行为验收清单
- [planner-adapter-dry-run-20260824.md](planner-adapter-dry-run-20260824.md) —— L3 干跑判定
- [psdk-udp-bridge-test-procedure-20260826.md](psdk-udp-bridge-test-procedure-20260826.md) —— L4 地面联调
- [measure-map-accuracy-5cm.md](measure-map-accuracy-5cm.md) —— L1 地图精度
- [exploration-run-recording-plan.md](exploration-run-recording-plan.md) —— 录包分级
- [domestic-deployment-guide-20260901.md](domestic-deployment-guide-20260901.md) —— 部署前置

## 附录 A：已废弃验证文档清单（仅标注，不删除）

以下文档对应 PX4/XTDrone/Indoor3 模拟时代，其验收项与当前 `sync_yyy` 基线、DJI
PSDK 控制路径不再一致，**不复制其中的验收标准作为当前判定依据**，保留仅作历史：

| 文档 | 内容 | 弃用理由 |
|---|---|---|
| `ego-px4-control-architecture.md` | 分阶段验收 A/B/C/D 与阶段 B 最低验收条件 | PX4/XTDrone 控制路径已被 DJI M400/PSDK 取代 |
| `xtdrone-ego-visual-baseline.md` | XTDrone 低速 EGO 视觉基线清单 | 仿真链路废弃 |
| `vision-injection-validation.md` | PX4 EKF 视觉注入验证记录 | 一次性实验，平台已换 DJI |
| `slam-gps-odom-comparison-20260801.md` | SLAM vs GPS/EKF 对比表 | 模拟时代数据；录包流程已被 8.1 取代 |
| `gazebo-simulation.md` | Gazebo 仿真验收设置 | 非实机链 |
| `board-ego-px4-odom-current-status.md` / `indoor3-*` / `current-indoor3-livo-ego-multiterminal-20260803.md` | indoor3 联调与多终端启动 | indoor3 时代的验收已从基线移除 |
| `slam-aware-goal-management-plan-20260804.md` | §10 验收标准 | 已被 Explorer goal 策略后续工作取代 |
| `imu-cloud-planning-deployment.md` | 10 Hz planning-cloud 部署检查 | 逻辑已重构，检查项并入 L1/L2 |
| `lio-controller-noetic-compatibility.md` | MAVROS/PX4 控制器兼容 | 控制器路径已弃用 |
| `repository-handoff-remote-integration-20260803.md` / `work-summary-remote-diff-20260803.md` | 远程联调验收快照 | 验收项早于 DJI 方向 |
| `px4-full-pipeline.md` | PX4 全链路 | 文内已注明控制架构重新决策，仅保留环境信息 |

## 附录 B：当前验证工具索引

| 工具 | 位置 | 用途 |
|---|---|---|
| 启动/验收脚本 | `scripts/start_*.sh`、`stop_daib_stack.sh` | 分层启动与 `[PASS]` 门 |
| 传感器时序校验 | `deploy/scripts/check_sensor_timing.py` | L0 阈值校验 |
| 时钟检查 | `scripts/ensure_clock.sh` | L0 时钟门 |
| LIO 实时性 | `scripts/measure_livo_hz.sh` | L1 100 ms 帧预算 |
| 地图精度 | `scripts/record_map_accuracy.sh`、`tools/bag_to_pcd.py`、`tools/measure_pcd_distances.py` | L1 精度判定 |
| 合成回归 | `tools/make_test_bag.py`、`tools/make_test_pcd.py`、`tools/test_board.*` | 无硬件回归 |
| 规划观察 watchdog | `scripts/daib_planning_watchdog.sh` | L2 运行健康 |
| 契约测试 | `src/DAIB-Explorer/test/`、`src/DAIB-Planner/src/planner/*/test/` | L2/L3 自动回归 |
| UDP 干跑接收器 | `tools/psdk_velocity_udp_receiver.py` | L4 链路校验 |
| 权限状态机模型 | `tools/psdk_mock_authority.py` | L4 离线验证 |
| 完整探索录包 | `scripts/record_fast_livo_inputs.sh`（输入）/ 手工 rosbag（A+B 层） | 记录与复现 |