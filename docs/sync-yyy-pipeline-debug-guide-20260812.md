# sync_yyy 主线：SLAM、Explorer、Planner 通路与分层调试指南

日期：2026-08-12

本文按当前 Orange Pi 镜像所用源码分析，不描述旧的 gpsless-cleanup 分支。所有后续
命令、参数判断、功能调试和代码修改一律以
[`CURRENT_SYNC_YYY_BASELINE.md`](CURRENT_SYNC_YYY_BASELINE.md) 声明的 `sync_yyy`
基线为准。

## 1. 当前基线

顶层工作分支：

```text
DAIB-UAV                 sync-yyy-main-build-fixes @ 本文所在提交
DAIB-LIVO                sync-yyy-main-build-fixes @ 58b3af5
DAIB-Explorer            sync-yyy-main-build-fixes @ 68e300c
DAIB-Planner             main / sync build fixes   @ e6f50a6
```

板端算法镜像：

```text
192.168.218.119:5050/daib-algorithm:openeuler-arm64
image id: b56cd5581f60
```

当前主线 `mapping_mid70_d435i.launch` 支持 `vio_img_point_cov`，默认值为 `100`。
launch 在加载 YAML 后覆盖 `/vio/img_point_cov`，因此启动命令传入的值会被
`laserMapping` 读取并用于 VIO EKF。新的 FAST-CALib batch2 外参和该 launch 接口以
`DAIB-LIVO` 当前 `sync-yyy-main-build-fixes` 分支提交为准。

当前记录的板端镜像 `b56cd5581f60` 早于该 LIVO 提交。必须重新构建并发布算法镜像、
记录新 image ID 后，才能按上述新接口进行板端验证。

## 2. 先用一句话理解整条链

```text
传感器给 SLAM 原始观测
  -> SLAM 估计“我在哪里”，并把本帧点云放进世界坐标
  -> Explorer 把点云变成“已知空闲 / 已知占用 / 未知”地图
  -> frontier 找出“已知空闲和未知世界的边界”
  -> Explorer 从边界附近挑一个任务目标
  -> Planner 判断怎么绕障碍飞到该目标，并生成平滑 B-spline
  -> traj_server 把曲线按时间采样成 PositionCommand
  -> 外部控制器才负责让真实飞机跟踪这些命令
```

可以把三层理解为：

| 层 | 回答的问题 | 不负责什么 |
|---|---|---|
| SLAM | 我在哪，眼前的点在世界哪里？ | 不决定去哪里 |
| Explorer | 接下来值得去哪里看？ | 不保证能生成动力学可行轨迹 |
| Planner | 给定目标，眼下怎样安全、平滑地过去？ | 不选择下一个 frontier |

## 3. 真实 ROS 数据通路

```text
/livox/lidar -----------+
/camera/imu ------------+--> FAST-LIVO ------------------------------+
/camera/color/image_* --+       |                                     |
                                | /daib_slam/odom                      |
                                | /daib_slam/planning_cloud            |
                                | /daib_slam/degenerate                |
                                | /daib_slam/degeneracy_score          |
                                | /daib_slam/lio_runtime_ms            |
                                | /daib_slam/pvbsm_delta               |
                                v                                     |
                         DAIB-Explorer                                 |
                           |                                           |
                           | /daib_explorer/frontiers  (仅观察)        |
                           | /daib_explorer/planning_cloud             |
                           | /daib_explorer/ready                      |
                           | /daib_explorer/goal                       |
                           | /daib_explorer/generation                 |
                           v                                           |
                     DAIB-EGO Bridge <---------------------------------+
                           |
                           | /daib_ego/goal
                           v
                     EGO planner FSM
                           |
                           | /drone_0_planning/bspline
                           v
                       traj_server
                           |
                           | /daib_ego/position_cmd
                           v
                    外部控制器（本仓库未闭合）
```

所有在线规划数据默认都在 `camera_init` 坐标系。可选的 LIVO loop backend 发布
`map` 下的全局修正结果，但默认 Explorer/Planner 没有消费它；局部控制链继续使用
连续、不跳变的 `camera_init`。

## 4. SLAM 层如何生产 Explorer 输入

FAST-LIVO 每次 LIO 更新后，用同一个 LiDAR 时间戳发布：

- `/daib_slam/odom`：位置、姿态和速度；
- `/daib_slam/planning_cloud`：当前降采样 LiDAR 帧变换到 `camera_init` 后的点；
- 退化标志、最小归一化特征值和本帧 LIO 耗时；
- 低频 PVBSM 增量，描述已观察过的平面/残差体素及所属 root。

planning cloud 不是累计全局地图。当前配置每帧最多取 `2048` 个点，按固定 stride
从本帧 `world_lidar` 中抽样。Explorer 必须把连续帧自己积成滚动地图。

PVBSM 也不是碰撞地图。它是“这里是否看过、结构证据有多少”的长期记忆，只参与
1 Hz 候选评分。

## 5. Explorer 的完整消费过程

### 5.1 输入门卫

Explorer 的 cloud 队列只有最新一帧。10 Hz timer 只有在以下条件都满足时才消费：

- odom 和 cloud 在最近 `1.0 s` 内收到；
- 两者 frame 相同；
- 两者时间戳差不超过 `0.2 s`；
- cloud schema 至少能读取 float `x/y/z`。

满足后发布 `/daib_explorer/ready=true`；否则 Planner Bridge 不转发新目标。

### 5.2 滚动占据图

地图分辨率为 `0.5 m`，半径 `40 m`，传感器射线最远 `20 m`。每个体素只有三种
语义：

```text
log_odds >=  2 -> occupied
log_odds <= -1 -> free
其他或不存在  -> unknown
```

每帧最多只做 `64` 条射线：沿射线经过的体素记 `-1`，终点记 `+2`，无人机当前
体素强制记 `-10`。LIO 忙时动态预算会把 64 条降到 32 或 16 条。

这层是 frontier 和 Explorer blocked 判断的唯一几何依据。它不是 FAST-LIVO 的
voxel map，也不是 Planner 的 grid map。

#### free/frontier 更新速度调试配置

如果实机上 free 空间和 frontier 变化明显滞后，可使用下面的临时高预算配置隔离
采样/预算因素：

```yaml
max_raycasts_per_update: 512
frontier_update_rate_hz: 10.0
frontier_update_budget: 4096
```

保持：

```yaml
planning_sensor_range_m: 20.0
planning_output_radius_m: 12.0
```

其中 `max_raycasts_per_update` 决定每个 cloud 实际用于射线更新的数量；后两个参数
分别决定 frontier 重算频率和每次最多处理的 dirty frontier 体素。该配置只用于现场
调试，不代表默认安全预算。日志应出现：

```text
budgets=512 rays/4096 frontier
```

若提高预算后 free/frontier 明显变快，说明原配置主要受预算限制；之后应在板端负载、
温度和 LIO 延迟之间选择折中值，而不是直接永久使用最高预算。

### 5.3 frontier 的真实定义

一个体素同时满足下面两项就是 frontier：

```text
自身是 known free
六邻域（上下、左右、前后）至少有一个 unknown
```

frontier 增量更新为 2 Hz，每轮最多处理 512 个 dirty 体素。它是完整三维定义，当前
没有地面/天花板抑制、法向约束或飞行高度切片。因此稀疏点云上下方也可能产生大量
frontier，并不天然等价于人眼理解的“房间门口”。

### 5.4 cluster 怎样判定

cluster 现在使用 planning voxel 的 18 邻域连通域，而不是把同一 `2 m` 空间桶直接
当成一组。frontier 合法性仍使用 6 邻域；18 邻域只负责分组，允许棱连接但不允许
纯角点连接。每个 frontier 在组成连通域前都会重新验证当前地图状态；已经变成
occupied、unknown 或不再满足 frontier 局部条件的旧点会被清掉。

连通域小于 `min_frontier_cluster_cells` 的会被拒绝。当前默认值是 `10`，即连通块
至少包含 10 个 planning voxel。因此：

- 同一 2 m 桶内但互不相连的点不会再合并；
- 跨越 2 m 边界但相邻的连续墙面仍然属于同一组；
- 单点和少量噪声 frontier 不会产生 goal 候选。

`frontier_cluster_size_m` 仍保留用于旧配置兼容，但当前不参与连通域判定。

日志中的 `components` 是原始连通分量数，`small_rejected` 是因数量不足被过滤的
分量数，`valid` 是最终参与 viewpoint 生成的 cluster 数，后面的 `cluster_ms` 是
这一步耗时。

### 5.5 每组怎样生成 safe viewpoint

对每个 cluster：

1. 求 frontier 中心点平均值；
2. 累加所有 unknown 六邻域方向，得到大致“未知空间方向”；
3. 从边界中心沿未知方向的反方向退 `1 m`，得到期望观察位；
4. 在期望位置周围最多 `2 m` 搜索 known-free 体素；
5. 要求离 occupied 至少 `0.5 m`，并且该点到 frontier 中心没有 occupied；
6. 找不到理想点时，回退到 cluster 内最近的安全 free frontier 体素。

注意：最终 goal 的 yaw 是“无人机当前位置指向 viewpoint”的行进方向，不是
“站在 viewpoint 看向未知区域”的观察方向。EGO 也只使用 goal 的 xyz，traj_server
再根据轨迹前视方向算 yaw。因此 Foxglove 中 goal 箭头朝向看起来不对，不一定代表
选点位置错。

### 5.6 打分前的隐藏筛选

cluster 先按近似航向分两档：`0~60 deg` 优先，`60~120 deg` 其次；同档内大 cluster
优先。然后每组只产生一个 viewpoint，直到达到候选上限。默认上限 64，LIO 忙时会
降到 32 或 16。

每个 viewpoint 还必须通过：

```text
距离                 1.5~8.0 m
相对当前高度差       <= 3.0 m
航向变化             <= 120 deg
不在失败目标冷却区   半径 1 m，持续 30 s
直线路径 known-free  比例 >= 0.5
```

这里的 known-free 比例只统计线段上明确 free 的体素。unknown 不算障碍，但会降低
比例；occupied 会立即判定直线被挡。当前不会为每个候选跑 A*。

### 5.7 最终评分公式

先对该 cluster 的“代表 frontier 体素”算基础信息分：

```text
base = 1.5 * 六邻域 unknown 数
     + 2.0 / (1 + 该 2m coverage cell 的访问次数)
     + 0.35 * 退化弱度 * 六邻域 occupied 数
```

再加长期记忆和运动成本：

```text
score = base
      + 退化时 4.0 * known_free_path_ratio
      + 未见 submap 奖励 1.0
      - submap 覆盖率 * 2.0
      - 已观察 root 惩罚 1.5
      + 退化时结构支持 * 0.75
      - 距离 * 0.5
      - 航向变化 / 120deg * 3.0
```

得分最高者成为 goal。cluster 点数本身没有进入最终分数，safe viewpoint 本身周围
有多少 unknown 也没有重新计算；使用的是 cluster 中最靠近中心的一个代表 frontier。

### 5.8 为什么 goal 不会每秒换

当前是持久目标策略，`allow_periodic_goal_switch=false`。一旦发布目标，就算出现更高分
frontier 也不会换，只有以下事件触发重新选点：

- 距离 goal 小于 `0.5 m`；
- 直线被挡且 bounded A* 判不可达，累计 blocked；
- `15 s` 内没有让历史最佳距离改善至少 `0.25 m`；
- 兼容用绝对 timeout（默认关闭）。

失败目标进入 30 s 冷却。active-goal A* 为 2 Hz，但 blocked streak 在 10 Hz 地图
更新中累加，因此当前实现可能重复使用同一个旧 A* 结果。

### 5.9 已确认缺陷：来源 cluster 消失不会撤销 active goal

2026-08-12 实机确认：一个 goal 发布后，其来源 frontier cluster 可以从当前连通聚类
结果中消失，但该 goal 仍保持有效。当前 `decision_` 没有保存稳定 cluster ID，也没有
在重聚类后检查 representative frontier 是否仍属于合法 cluster。

默认 `allow_periodic_goal_switch=false` 时，已有 goal 且未被判断为 reached、blocked、
stalled 或 timeout，`updateDecision()` 会在调用 `frontierClusters()` 之前返回。即使打开
周期切换，如果当前轮没有新 candidate，代码仍保留未失败的旧 goal。因此这不是单纯
调低 `replan_interval_s` 可以解决的问题。

还要区分两层残留：

- 算法残留：Explorer 内部仍认为旧 goal 有效，可能继续被 Bridge/Planner 执行；
- 显示残留：`/daib_explorer/goal`、`/daib_ego/goal` 都是 latched topic，内部撤销后若
  不发布显式无效状态，Foxglove 和新订阅者仍会看到最后一条旧 goal。

修复要求是每轮先验证 active goal 的来源 cluster。cluster 消失时，有替代候选则立即
发布下一代 goal；没有替代候选则进入 `WAIT_FOR_FRONTIER` 并发布显式
`goal_valid=false`。Bridge 必须消费该状态并停止执行旧目标，调试 Marker 同时发送
`DELETE`。

### 5.10 待实现：Explorer 自有全局观测记忆

当前 rolling occupancy 在 `planning_map_radius_m` 外会裁剪，而 `visits_` 只记录无人机
经过的 coverage cell。为避免旧区域重新成为 frontier，计划由 Explorer 的 LiDAR
raycast 同步维护任务期全局 `exploration_memory_`，不依赖 SLAM voxel 或 PVBSM。

射线经过的 1 m 粗体素累计 free observation，终点累计 surface observation，终点后方
不更新。所有 cell 先按帧去重，每帧最多累计一次；计数饱和，至少三个不同帧观测才算
稳定 observed。第一版不随 12 m/40 m 窗口裁剪、不写磁盘，Explorer 重启时清空。

cluster 合法性检查沿 unknown 方向从边界后 1 m 开始采样到 4 m。若稳定 observed 的
采样比例达到 0.7，则视为局部地图遗忘造成的历史 frontier 并拒绝。该记忆只用于探索
新颖性，不能作为当前 free 状态或碰撞安全证据。

初始参数建议为：

```yaml
exploration_memory_enabled: true
exploration_memory_voxel_size_m: 1.0
exploration_memory_min_observations: 3
exploration_memory_max_range_m: 20.0
frontier_history_probe_distance_m: 4.0
frontier_history_probe_step_m: 1.0
frontier_history_observed_ratio: 0.7
```

实现时需要记录 memory cell 数量、每帧新增/强化数量、历史 cluster 拒绝数和 observed
probe ratio，并用“首次进入、离开局部地图后返回、遮挡墙后区域、单帧噪声”四类场景
验收。

## 6. Planner 如何消费 Explorer 输出

### 6.1 Bridge 是协议门卫，不是规划器

Bridge 同时看 Explorer ready、SLAM odom、goal 和 generation。它检查：

- ready 心跳新鲜（2.5 s）；
- odom 新鲜（1.0 s）；
- goal/odom 都是 `camera_init`；
- goal 时间、数值、高度和距离合法；
- 不是已转发的重复 goal。

通过后把 `/daib_explorer/goal` 转成 `/daib_ego/goal`。generation 主要用于确认和
监控，并没有随 goal 以一条原子消息送入 EGO。

### 6.2 Planner 又建了一张地图

Explorer 发布半径 12 m 内的 occupied voxel centers 到
`/daib_explorer/planning_cloud`。EGO grid map 再用 `0.25 m` 分辨率落栅格，并在 XY
方向膨胀 `0.5 m`、Z 方向膨胀一个 voxel。

所以同一障碍经过两层离散化：

```text
SLAM 点 -> Explorer 0.5m occupied voxel -> Planner 0.25m grid + 0.5m inflation
```

Explorer 认为 viewpoint 安全，不代表 EGO 的膨胀地图一定可走。调试 Planner 地图
应看 `/drone_0_ego_planner_node/grid_map/occupancy_inflate`；当前 independent-cloud
路径只写 inflate buffer，普通 `occupancy` 可能为空。

### 6.3 EGO 的两级路径

新 goal 到达后：

1. 从当前 odom 到 goal 生成一条全局多项式参考线；
2. 在参考线上取最多约 `7.5 m` 的 local target；
3. 用当前位置/上一条轨迹作为起点，参数化 B-spline 控制点；
4. 优化平滑、碰撞、速度和加速度代价；
5. 发布 B-spline；
6. 执行中每约 1 s 或遇到碰撞风险重新规划。

traj_server 以 100 Hz 采样 B-spline，发布位置、速度、加速度、yaw 和 yaw rate 到
`/daib_ego/position_cmd`。这仍是控制器输入，不是可直接发给 DJI/PX4 的最终协议。

## 7. 当前闭环中最重要的缺口

### 7.1 Planner 没有把执行结果反馈给 Explorer

当前通路是单向的：

```text
Explorer goal -> Bridge -> EGO
```

没有 `PLANNING / BLOCKED / REACHED` 按 generation 回传。EGO 若因膨胀地图或动力学
约束一直规划失败，Explorer 并不知道，只能靠自身 odom 推断 15 s stall 后换目标。

### 7.2 Explorer 的 PVBSM voxel 配置与 LIVO 不一致

当前配置为：

```text
LIVO lio/voxel_size                 0.5 m
Explorer pvbsm_root_voxel_size_m    1.0 m
```

Explorer 自己的注释明确要求两者相同。这个 2 倍尺度差会让候选查询到错误的 root 和
submap，进而改变 unseen/coverage/observed-root 分数。调试纯 frontier 几何时应先关闭
`pvbsm_scoring_enabled` 做基线；确认 root 定义后再修正并重新打开。

### 7.3 中间候选目前完全不可视

现在只有：

- `/daib_explorer/frontiers`：所有原始 frontier；
- `/daib_explorer/goal`：最终目标；
- 日志：各类 reject 总数。

看不到哪个 frontier 属于哪组、理想 viewpoint、实际 viewpoint、淘汰原因和各项分数。
因此仅看最终 goal 无法判断问题发生在哪一级。

### 7.4 已知策略风险

- 18 邻域能连接棱相邻的稀疏斜向 frontier，但复杂交界处仍可能产生错误合并；
- active goal 的来源 cluster 消失后不会立即撤销；
- goal topic 是 latched，缺少显式 invalid 协议时还会产生显示残留；
- cluster 大小不参与最终信息收益；
- 先按 heading tier 截断，第二档合理目标可能根本没有进入评分；
- 只有 64/32/16 条射线更新 Explorer 地图，可能产生稀疏条纹和假 frontier；
- 全三维六邻域 frontier 容易把上下未知区当探索边界；
- 只有相对高度限制，没有绝对高度和 geofence；
- A* 预算耗尽被当成不可达；
- 一次 negative A* 结果可能在多次 10 Hz update 中重复累计 blocked；
- goal yaw 表示行进方向，不表示相机观察方向。

## 8. 从 frontier 开始的可视化调试阶梯

不要一开始同时启动完整闭环。每一级先证明其输入正确，再打开下一级。

### 第 0 层：SLAM 输出

Foxglove 同时显示：

```text
/daib_slam/planning_cloud
/daib_slam/odom
```

检查点云是否随位姿稳定落在 `camera_init`，静止时墙面是否稳定，时间戳是否同步。
这一层不通过，不调 Explorer。

### 第 1 层：Explorer 占据图

只启动 SLAM + Explorer，Planner 关闭。显示：

```text
/daib_slam/planning_cloud          原始本帧输入
/daib_explorer/planning_cloud      Explorer 判断的 occupied
```

重点看假障碍、漏墙、机体附近 occupied 和抽样条纹。需要录包时记录上述两个 topic、
odom、degenerate、lio_runtime，而不是依靠终端滚动输出。

### 第 2 层：原始 frontier

增加 `/daib_explorer/frontiers`，先观察 frontier 是否真正在已知/未知边界。如果大量点
铺在地板上下表面、天花板或零散噪声周围，问题还在地图/frontier 定义，不应调 goal
权重。

第一轮 A/B 建议：

```text
固定一份 rosbag
pvbsm_scoring_enabled=false
dynamic_budget_enabled=false
保持其他默认参数
```

这样先排除长期记忆和负载缩预算对结果的影响。

### 第 3 层：cluster 与 viewpoint（需要补可视化）

建议给 Explorer 增加 MarkerArray 调试输出：

```text
/daib_explorer/debug/frontier_clusters    每组不同稳定颜色
/daib_explorer/debug/viewpoints           通过筛选的球体
/daib_explorer/debug/rejected_viewpoints  按原因着色
/daib_explorer/debug/view_rays            viewpoint -> frontier centroid
```

颜色应固定表示原因，例如 distance、vertical、heading、known_path、cooldown，而不是
每帧随机。Marker ID 用稳定 cluster key，下一帧显式 DELETE 旧 marker。

这一层回答：奇怪 goal 是因为 frontier 分错组，还是安全观察位生成错了。

### 第 4 层：评分（需要补结构化诊断）

为每个最终候选发布一条结构化记录或 Marker text：

```text
cluster_id, viewpoint xyz, representative frontier xyz
unknown_neighbors, visits, occupied_neighbors
known_free_ratio, distance, heading
pvbsm unseen/coverage/root_observed/structure
各分项和 total score, rank, reject reason
```

先 `PVBSM off` 验证纯几何排名，再 `PVBSM on` 对比。只看 total score 不够，因为不同
分项可能互相抵消。

### 第 5 层：目标保持状态机

显示当前 goal、历史轨迹、距 goal、历史最佳距离、last-progress age、blocked streak、
A* 结果和 cooldown 圆。分别人工制造 reached、blocked、stall，确认 generation 只在
真正换目标时增加。

### 第 6 层：Bridge

启动 Bridge/EGO 前先确认：

```text
/daib_explorer/ready
/daib_explorer/goal
/daib_explorer/generation
/daib_ego/bridge_state
/daib_ego/goal
/daib_ego/accepted_generation
```

录一个短 bag 检查同一目标是否原样到达，不先讨论轨迹质量。

### 第 7 层：Planner 地图和轨迹

显示：

```text
/daib_explorer/planning_cloud
/drone_0_ego_planner_node/grid_map/occupancy_inflate
/daib_ego/goal
/drone_0_ego_planner_node/optimal_list
/daib_ego/position_cmd
```

当前 FSM 中 `goal_point` 的发布调用已被注释，不能把它当成可靠目标显示；10 Hz
采样后的活动 B-spline 复用 `optimal_list` Marker topic，而不是独立的
`active_trajectory` topic。

先只生成轨迹，不连接真实控制器。判断失败是 goal 被 Bridge 拒绝、EGO 地图膨胀挡住、
B-spline 优化失败，还是轨迹生成后没有控制消费者。

## 9. 推荐的实际调试顺序

1. 固定一份能复现“goal 奇怪”的 rosbag，所有改动都回放同一份数据。
2. 验证 SLAM odom/cloud，确认不是坐标或时间问题。
3. 关闭 Planner 和 PVBSM scoring，只看 Explorer occupied 与 raw frontier。
4. 补 cluster/viewpoint/reject 可视化，定位候选生产问题。
5. 补逐候选分项，验证纯几何评分。
6. 修正 PVBSM root 尺度后再打开长期记忆，做 on/off 对照。
7. 验证 persistent goal 的 reached/blocked/stall/cooldown。
8. 再接 Bridge，确认 goal 协议层。
9. 再接 EGO grid map 与 B-spline，最后才接控制器。

按这个顺序，每次只新增一个变量。否则最终飞行方向异常时，SLAM、frontier、评分、
Planner 膨胀和控制器五层都会同时成为嫌疑。
