# 本地变更与算法影响审计

日期：2026-08-09

## 目的

本文用于区分以下三类工作，避免把所有本地提交都笼统地称为“修改原算法”：

1. 为 ARM64、ROS Noetic、传感器和 PX4 链路做的兼容与集成工作；
2. 会改变运行时状态机、数据流或安全策略，但不改核心优化目标的系统行为修改；
3. 会改变状态估计、建图、探索目标或规划决策的算法修改。

本文只审计本地已有提交，不评价实验效果是否已经充分验证，也不改动源码。

## 三层基线

讨论“原版”时必须明确指哪一层：

| 层级 | 含义 | 用途 |
|---|---|---|
| 公开上游 | FAST-LIVO2、EGO-Swarm 等公开项目 | 判断是否改变原始学术算法 |
| 同学远端 | 三个子模块各自的 `origin/main` | 判断是否偏离当前协作代码 |
| 本地分支 | 三个子模块各自的 `jaluova/main` / 本地 `main` | 当前可运行化和本地改进 |

一个提交可能偏离同学远端，但反而更接近公开上游。例如 LIVO 的稳定基线恢复
删除了同学后来加入的 DAIB-CEM、PVBSM 和视觉记忆层；它明显改变了同学的 DAIB
路线，但不是继续改写公开 FAST-LIVO2 的核心算法。

本次审计基于本地已有的远端跟踪引用，没有执行 `git fetch`。审计时所有工作树均
无未提交修改：

| 模块 | 同学基线 | 本地版本 | 本地领先 |
|---|---|---|---|
| DAIB-LIVO | `origin/main` `c23dba5` | `ac4bc17` | 9 个提交（含 2 个合并提交） |
| DAIB-Explorer | `origin/main` `cec679f` | `111c481` | 1 个提交 |
| DAIB-Planner | `origin/main` `cf9784f` | `696bbe1` | 5 个提交 |

## 总体判断

| 模块 | 主要本地工作 | 对同学算法的影响 |
|---|---|---|
| DAIB-LIVO | 稳定基线恢复、MID-70/D435i、规划点云、ARM64 构建，以及后来被回退的 IMU 高频里程计尝试 | **高**：删除了一组同学新增算法，同时保留了后续回环后端 |
| DAIB-Explorer | 聚类安全视点、路径已知自由比例、围栏和目标保持策略 | **高**：直接改变探索候选过滤和目标切换 |
| DAIB-Planner | PX4 坐标桥、安全锁止、观测地图、诊断和 XTDrone 输出 | **中到高**：多数不改 EGO 优化器，但改变输入地图、状态机和最终轨迹执行行为 |

因此，当前分支不能整体描述为“仅兼容性修改”。比较准确的说法是：

> 在保留公开算法主体的基础上，完成了硬件与控制链路适配；同时撤回了部分未稳定的
> DAIB-LIVO 扩展，并新增了探索目标生成和观测地图算法。

## DAIB-LIVO 逐提交审计

| 提交 | 分类 | 是否改变算法行为 | 审计结论 |
|---|---|---|---|
| `ee1deac` | 接口与运行语义 | 当时会间接改变下游行为 | 曾在每个 IMU 样本间传播最近一次 LiDAR 校正状态并发布高频 odom；不改 LIO `StateEstimation` 目标，但会改变规划使用的状态频率、时间戳和失效处理。该实现后来被 `9eee7fd` 大部分回退，当前只剩原有的可选 `/LIVO2/imu_propagate` 机制，不能视为现行 DAIB 接口。提交还包含跨 CPU 编译参数调整，性质混杂。 |
| `b4674be` | 仿真兼容 | 否 | 新增 LIO-only XTDrone 启动入口，不改核心实现。 |
| `37fcb30` | 标定与仿真适配 | 参数层面会改变结果 | 使用 XTDrone 相机内外参；公式未变，但估计结果当然会随正确参数变化。 |
| `538ef4f` | 默认运行模式 | 是，可配置回退 | 仿真默认启用 VIO。没有新增算法，但改变默认走 LIO 还是 LIVO。 |
| `9eee7fd` | **算法路线回退** | **是，影响最大** | 删除自适应视觉帧选择、退化感知信息预算 LIO、DAIB-CEM 视觉记忆、PVBSM 及相关协议和测试，恢复稳定 FAST-LIVO2 式主链。它解决稳定性问题，但必须作为明确的路线选择单独评审。 |
| `9883f56` | 合并策略 | **是** | 合并同学的 PVBSM 更新历史，但明确不恢复已删除的 PVBSM 实现。它记录了分支关系，没有消除算法分歧。 |
| `a8f489a` | 混合提交 | 部分会 | ARM64 可移植编译、MID-70/D435i 配置和投影诊断属于兼容性；LiDAR 原始帧规划云属于接口；`vio/state_update_en` 可关闭视觉 EKF 修正，属于算法行为开关。后续对接时应拆成三个变更包讨论。 |
| `d117c60` | 上游能力合并 | 保留同学算法 | 接收 `c23dba5` 轻量回环后端；冲突处理中同时保留本地传感器工具和同学回环目标。 |
| `ac4bc17` | 构建兼容 | 否 | 为所有目标补齐 OpenMP 链接，不改运行逻辑。 |

### LIVO 当前结论

- 当前主前端不是同学 `origin/main` 的完整 DAIB-LIVO：PVBSM、退化度量、视觉选择
  和 CEM 视觉记忆已被移除。
- `ee1deac` 文档中描述的 `/daib_slam/imu_odom` 已随稳定基线恢复而回退；当前
  `uav/imu_rate_odom` 默认关闭，原有发布名仍是 `/LIVO2/imu_propagate`。
- 当前仍包含同学后续的轻量回环后端，但该后端默认订阅 `/daib_slam/odom`、
  `/daib_slam/planning_cloud` 和 `/daib_slam/degenerate`；恢复后的主前端并不直接
  发布这组三个话题。
- MID-70/D435i 默认配置关闭 `planning_cloud_lidar_en`。只启动默认实机 launch
  时适合独立 LIO 验收，但不能直接给 PX4 planning-cloud bridge 提供输入。

## DAIB-Explorer 逐提交审计

| 提交 | 分类 | 是否改变算法行为 | 审计结论 |
|---|---|---|---|
| `111c481` | **探索算法与运行配置** | **是** | 在同学已有的 motion-constrained frontier 基础上增加聚类安全视点约束、绝对高度/围栏过滤、路径已知自由比例过滤，并默认禁止周期性换目标；同时把目标保持从 3 s 调到 5 s、超时从 12 s 调到 45 s。会直接改变候选集合、目标稳定性和探索轨迹。 |

这是本地最明确的算法改进之一，不应归到“兼容性”。它已有核心单元测试和 ROS
运行契约测试，但仍需要相同 rosbag/场景下与 `cec679f` 做 A/B 对比，重点观察：

- 有效 frontier 数、无目标周期和探索覆盖率；
- 目标切换次数、回头和贴墙目标数量；
- `min_known_free_path_ratio=1.0` 是否在稀疏点云下过严；
- 45 s 目标超时是否造成长时间卡在低收益目标。

## DAIB-Planner 逐提交审计

| 提交 | 分类 | 是否改变算法行为 | 审计结论 |
|---|---|---|---|
| `0a33e3c` | 输入安全与 FSM | 改变规划状态机 | 增加 odom 新鲜度、非有限值检查和掉线急停；不改 B-spline 优化目标，但会拒绝旧目标并改变急停/重启条件。 |
| `157f67a` | XTDrone 接口兼容 | 不改规划算法 | 从同一轨迹额外发布 `geometry_msgs/Pose`；改变输出接口，不改变轨迹本身。 |
| `81f29da` | 诊断与可视化修复 | 基本不改 | 增加拒绝原因日志；修复独立点云模式的 occupancy 可视化；规划失败时不再把未优化控制点伪装成成功轨迹。 |
| `0cfaffb` | 坐标桥与安全策略 | 改变系统行为 | 新增 LiDAR 点云到 PX4 `map` 的时间插值变换、不可逆 planning-input fault latch、cloud/odom watchdog 和可配置 yaw 限速。EGO 优化器主体未改，但输入坐标、允许规划的条件和执行 yaw 都改变。 |
| `696bbe1` | **建图算法与数据链** | **是** | 新增 observation-aware local/global voxel map；局部图通过射线清空和命中累积保留离开视野的障碍，并把 EGO 输入从瞬时规划云切为 `/daib_map/local/cost_cloud`。这是独立建图算法，不是单纯兼容层。 |

Planner 的两个核心算法主体边界应这样描述：

- EGO-Swarm 的 B-spline 代价函数和主要优化流程基本保留；
- EGO 的输入地图、FSM 门禁、急停策略和 yaw 输出语义已有显著改变；
- `daib_global_map` 是本地新增算法模块，应独立评价，不应包装成 EGO 原算法修复。

## 当前跨模块阻断项

### 1. Explorer 输入契约与 LIVO 输出不一致

Explorer 默认需要：

```text
/daib_slam/odom
/daib_slam/planning_cloud
/daib_slam/degenerate
/daib_slam/degeneracy_score
/daib_slam/lio_runtime_ms
/daib_slam/pvbsm_delta
```

当前恢复后的 LIVO 主前端实际核心输出是：

```text
/aft_mapped_to_init
/cloud_registered
/daib_slam/planning_cloud_lidar   # 可选，实机默认关闭
```

因此当前代码库包含 Explorer 算法和 LIVO 算法，并不等于默认启动后两者已形成完整
运行契约。可以通过显式适配运行部分功能，但退化感知和 PVBSM 评分没有数据源。

### 2. PVBSM 已删除，但 Explorer 默认启用

LIVO 已删除 PVBSM 发布实现，Explorer 的 `pvbsm_memory_enabled` 和
`pvbsm_scoring_enabled` 却都默认为 `true`。这不会必然让 Explorer 进程崩溃，
但会使代码宣称的长期结构记忆与实际运行能力不一致。

### 3. LIVO 测试构建引用已删除文件

合并回环后，LIVO `CMakeLists.txt` 仍登记：

```cmake
catkin_add_gtest(pvbsm_test test/pvbsm_test.cpp)
```

但 `test/pvbsm_test.cpp` 已在稳定基线恢复中删除。关闭测试的镜像构建可能绕过该
问题，启用 `CATKIN_ENABLE_TESTING` 时会暴露。应在路线确定后选择恢复测试和实现，
或一起删除残留测试目标。

### 4. 默认实机启动只覆盖 LIO 验收

当前 `ALGORITHM_LAUNCH` 默认启动 `mapping_mid70_d435i.launch`，并且默认
`use_camera:=false`、规划 LiDAR 云关闭。它适合先验收传感器和 LIO，但不能代表
Explorer、Planner、观测地图和控制闭环已经验收。

## 对接拆分建议

不要把三个本地分支整体交给同学一次性评审。建议按以下独立变更包对接：

1. **纯兼容包**：ARM64/OpenMP、MID-70/D435i 驱动配置、投影与时间诊断工具。
2. **接口包**：当前的 LiDAR-frame planning cloud 和 PX4 时间插值坐标桥；如果仍
   需要 IMU-rate odom，应从 `ee1deac` 重新提取并作为独立改动验证，而不是宣称
   当前分支已经具备该接口。
3. **安全包**：odom/cloud watchdog、fault latch、yaw 限速和拒绝诊断。
4. **LIVO 路线决策**：保留 DAIB-CEM/PVBSM，还是维持稳定 FAST-LIVO2 前端；这是
   架构选择，不能伪装成普通 bugfix。
5. **Explorer 算法包**：聚类安全视点和目标保持策略，单独做 A/B 数据评审。
6. **观测地图算法包**：`daib_global_map`，单独评审占据更新、遗忘策略和 EGO 接入。
7. **回环包**：轻量回环后端及其真正可用的前端输入适配。

每个包至少附带以下证据：基线 commit、启动参数、固定 rosbag/场景、关键话题频率、
CPU/内存、成功指标和失败现象。兼容性包可以以“能否构建/启动”为主要标准；算法包
必须使用相同输入做 A/B，不能只凭 RViz 看起来更顺。

## 可以直接用于对接的表述

> 我这边的分支不是纯兼容补丁。兼容部分包括 ARM64/OpenMP、MID-70/D435i、
> ROS/PX4 接口和诊断工具；系统行为部分包括 odom/cloud watchdog、坐标桥和安全锁止；
> 算法部分包括 Explorer 聚类安全目标和 observation-aware map。另有一项明确的路线
> 分歧：为了恢复稳定运行，我撤掉了当前 DAIB-LIVO 前端里的 CEM/PVBSM/视觉选择，
> 但保留了后续回环后端。我们需要先决定 LIVO 前端路线，再分别评审兼容包和算法包，
> 不建议直接把整个分支互相覆盖。
