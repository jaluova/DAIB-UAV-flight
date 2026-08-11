# DAIB-Explorer 目标策略修改交接（给 YYY 仓库 Agent）

日期：2026-08-10

本文是一份可以独立阅读的实现说明。接手修改的 Agent 不应假设自己了解此前的聊天、
板端测试过程或两个仓库之间的分支关系。

## 1. 任务目标

在同学当前 `DAIB-Explorer` 主线基础上，合入 `jaluova/main` 已有的目标稳定性
修改，并删除或简化当前运动约束实现中过度限制 frontier 的部分。

最终行为必须满足四条来自实际运行的经验：

1. 探索目标不能离无人机当前位置过远。
2. 不要直接发布要求无人机约 180 度大转弯的目标。
3. frontier 本身不需要很多硬限制；候选应尽量产生，再由运动代价选择。
4. 一个已接受目标在无人机到达前不能仅因为出现了更高分 frontier 就改变。

整体思路参考 FUEL 的职责划分：

```text
frontier 层：宽松地产生可观察候选
运动代价层：优先短距离、较小转向的候选
任务状态层：保持当前目标，直到到达、确认阻塞或确认停滞
```

这不是重新设计一套 Explorer，也不是修改 LIVO 或 Planner。

## 2. 仓库和提交基线

主仓库工作区中的 Explorer 路径：

```text
src/DAIB-Explorer
```

远端关系：

```text
origin   = https://github.com/YYY0702/DAIB-Explorer.git
jaluova  = https://github.com/jaluova/DAIB-Explorer.git
```

关键提交：

```text
cec679f4c6b2367cfd57cbbf3cc839bebedc6225
feat: add motion-constrained safe frontier selection
作者：小羊
日期：2026-08-08
位置：YYY0702/origin/main

111c481839d8017cc9bb44b06e77e694b8fecc7f
feat: add clustered safe exploration goals
作者：jaluova
日期：2026-08-09
位置：jaluova/main
```

`111c481` 是 `cec679f` 的直接后继，因此 cherry-pick 不应有文本冲突。不要回退、
重写或 force-push `cec679f`；应在它上面应用 `111c481`，再提交一个独立的行为修正。

建议分支：

```bash
git fetch origin
git remote get-url jaluova >/dev/null 2>&1 || \
  git remote add jaluova https://github.com/jaluova/DAIB-Explorer.git
git fetch jaluova
git switch -c agent/explorer-fuel-goal-policy origin/main
git cherry-pick 111c481839d8017cc9bb44b06e77e694b8fecc7f
```

如果目标分支已经包含 `111c481`，不要重复 cherry-pick。

## 3. 运行环境与接口边界

当前板端为 Orange Pi 5 Max，Ubuntu 22.04，用户为 `orangepi`。实际飞行平台为
大疆无人机，任务走无 GPS 路线。本任务只处理 Explorer 的任务目标策略，不改飞控
适配器。

当前同学主线使用并且必须保持的 Explorer 输入接口：

```text
里程计：/daib_slam/odom
点云：  /daib_slam/planning_cloud
坐标系：camera_init
```

不要把 Explorer 默认接口改成 `/aft_mapped_to_init`、`/cloud_registered`、
`/daib_slam/imu_odom` 或 PX4 `map` 坐标系。本次也不要修改 DAIB-LIVO、
DAIB-Planner、Docker 镜像或控制器。

## 4. 已观察到的实际问题

同学当前算法镜像播放真实 bag 时，Explorer 有如下典型日志：

```text
map=1400 free/309 occupied/992 frontier
mcsvf=66 clusters/0 viewpoints/0 reachability_checks
```

同时 PVBSM 的 roots、records、submaps 持续增长。这说明：

```text
LIVO -> Explorer 的 odom/cloud 输入正常
rolling map 和 frontier 正常增长
候选在安全视点生成或后续硬过滤阶段被全部清空
没有目标发送给 Planner
```

`safe_viewpoint_candidates` 当前是在距离、高度、爬升角、路径和航向过滤全部完成后
赋值，因此日志里的 `0 viewpoints` 不等价于“只在 makeSafeViewpoint() 失败”。

## 5. 当前实现中需要保留的部分

以下代码和能力必须保留：

- incremental occupancy/frontier 更新；
- frontier 聚类框架；
- `viewpoint_standoff_m`，目标不要直接落在未知边界上；
- 基本障碍净空检查；
- PVBSM memory 和可选评分；
- LIO 动态计算预算；
- 多频率调度；
- 机体自身占据清除；
- `/daib_explorer/goal`、`generation`、`ready` 等 Planner 接口；
- `111c481` 增加的 launch 参数覆盖；
- `111c481` 增加的 geofence 和绝对高度边界能力；
- `111c481` 增加的 `allow_periodic_goal_switch` 行为和对应测试。

不要为了简化目标选择而删除 PVBSM、接口协议或资源控制代码。

## 6. 当前实现中需要修改或删除的部分

### 6.1 删除“偏爱远目标”的分级

当前配置：

```yaml
preferred_min_goal_distance_m: 4.0
```

当前候选分级会把距离至少 4 米且航向较小的候选放入最高优先级，这与实测经验
相反。删除 `preferred_min_goal_distance_m` 参数、sanitize 逻辑和候选 tier 判断。

首轮建议距离范围：

```yaml
min_goal_distance_m: 1.5
max_goal_distance_m: 8.0
```

`8.0 m` 是硬上限。距离上限应作用于最终 viewpoint，而不是 frontier 聚类质心。

### 6.2 保留方向约束，但禁止放开到 180 度

当前实现包含：

```text
0~60 度：优先 tier
60~120 度：fallback tier
120~180 度：loop_escape 时允许
```

修改为：

```yaml
preferred_heading_change_deg: 60.0
max_heading_change_deg: 120.0
```

要求：

- `heading <= 60`：有较低运动代价；
- `60 < heading <= 120`：仍可选择，但运动代价更高；
- `heading > 120`：本轮不发布该候选；
- 不允许任何自动模式重新放开到 180 度。

删除以下代码和配置：

- `fallback_heading_change_deg` 的 180 度逃逸语义；
- `loop_escape_enabled` 及所有 `loop_*` 参数；
- `goal_history_`、`loop_escape_until_`、cluster blacklist；
- `loopDetected()`、`recentlySelectedCluster()`、`rememberSelectedCluster()`；
- `selected_tier` 只保留最低档候选的硬分级逻辑；
- `loop_escape` 相关状态和日志字段。

候选仍需有 `120` 度硬上限，但上限以内建议采用连续运动代价，不要再通过 tier
完全屏蔽其他候选。推荐评分结构：

```text
final_score = information_score
            + pvbsm_adjustment
            - distance_cost
            - heading_cost
```

实现时应把 `frontierScore()` 当前内置的 `-0.25 * distance` 移到明确的运动代价
部分，避免重复扣分。建议初始形式：

```text
distance_cost = 0.5 * candidate_distance_m
heading_cost  = 3.0 * heading_change_deg / max_heading_change_deg
```

两个权重必须做成 ROS 参数，以便 bag A/B 调整。硬上限比具体权重更重要。

### 6.3 已接受目标必须保持

应用并保留 `111c481` 中的：

```yaml
allow_periodic_goal_switch: false
```

目标状态转换必须严格限制为：

```text
NO_GOAL  --选择成功--> ACTIVE
ACTIVE   --到达------> NO_GOAL/选择下一个
ACTIVE   --持续阻塞--> NO_GOAL/选择下一个
ACTIVE   --持续无进展> NO_GOAL/选择下一个
ACTIVE   --出现更高分 frontier--> ACTIVE（保持原目标）
```

当前固定 `goal_timeout_s: 45.0` 会让正在缓慢接近的无人机仅因为时间到达而换目标，
不符合要求。不要使用绝对存活时间作为换点条件。

新增进展判断参数：

```yaml
goal_progress_epsilon_m: 0.25
goal_stall_timeout_s: 15.0
failed_goal_exclusion_radius_m: 1.0
failed_goal_cooldown_s: 30.0
```

建议实现：

1. 发布新目标时记录 `best_goal_distance` 和 `last_goal_progress_time`。
2. 每次 odom/cloud 更新计算当前位置到目标的距离。
3. 当距离比历史最佳值至少减少 `goal_progress_epsilon_m` 时，更新历史最佳值并重置
   `last_goal_progress_time`。
4. 只有连续 `goal_stall_timeout_s` 没有有效接近时，才设置 `goal_stalled=true`。
5. `goal_stalled` 或持续 blocked 后，把原目标位置记录为短期 failed goal；在
   `failed_goal_cooldown_s` 内拒绝其 `failed_goal_exclusion_radius_m` 范围内的候选。
6. `goal_stalled` 可以触发重新选点；正常持续接近时不应触发。
7. 如果没有其他合规候选，Explorer 进入 `WAIT_FOR_FRONTIER`，不得立即重新发布同一个
   失败目标；冷却到期后才允许重新评估。注意：Explorer 的等待状态本身不是飞控悬停
   命令，也不会自动取消 Planner 已有轨迹。
8. 新目标、目标到达、目标失效时重置进展状态，但 failed-goal 冷却记录独立保留到
   到期，避免重新选点时立刻命中原目标。

可以保留 `goal_timeout_s` 参数用于向后兼容，但默认应为 `0`（禁用），并在文档中
标记 deprecated。不要同时启用绝对 timeout 和 progress stall timeout。

### 6.4 frontier 候选层做减法

首轮建议参数：

```yaml
frontier_cluster_size_m: 2.0
min_frontier_cluster_cells: 1
viewpoint_standoff_m: 1.0
viewpoint_search_radius_m: 2.0
min_wall_clearance_m: 0.5
max_safe_viewpoint_candidates: 64
min_known_free_path_ratio: 0.5
```

具体要求：

- 保留聚类，但不要因为一个 cluster 只有 1~2 个 frontier voxel 就直接丢弃；
- 保留 standoff；
- 最终 viewpoint 必须位于已知自由体素；
- 净空仍然是硬约束，但与 Planner 当前 `0.5 m` 障碍膨胀保持一致；
- `min_known_free_path_ratio` 不要默认 `1.0`，稀疏射线地图无法稳定证明整段路径
  100% 已知自由；
- 保留 geofence 和 `min_goal_z_m/max_goal_z_m`；
- 删除 indoor/outdoor 两套重复的垂直距离和 climb-angle 硬过滤；
- 如仍需相对高度限制，只保留一个 `max_goal_vertical_distance_m`；
- 不要同时叠加 absolute Z、scene vertical distance 和 climb angle 三套过滤。

`makeSafeViewpoint()` 仍应优先寻找后退的已知自由点。为避免一个理想后退点失败就
丢弃整个 cluster，可增加一个保守 fallback：在该 cluster 自身的 frontier free
voxels 中寻找满足净空且距离限制合格的点。fallback 仍不能返回 occupied voxel 或
geofence 外的点。

### 6.5 A* reachability 只用于当前目标状态，不用于大量候选硬过滤

Explorer 的任务是提供任务级目标，实际局部绕障由 EGO-Planner 完成。当前每轮对
候选执行 bounded A* 会增加复杂度并进一步清空 frontier。

调整要求：

- 从候选生成循环中删除 `pathReachable()` 硬过滤；
- 保留低频的 active-goal reachability 检查；
- 当当前目标直线被占据时，active-goal A* 可以避免把“能绕过去”的目标过早标记为
  blocked；
- active-goal A* 继续受 expansion budget 和检查频率限制；
- `goal_blocked_confirm_updates: 10` 保持，单帧障碍不能触发换点。

如果 Planner 后续提供明确的目标失败反馈，再考虑用 Planner 反馈替代 Explorer 内部
A*。本次不要扩展 Planner 接口。

当前 Explorer 没有收到 EGO “规划失败/动力学不可达”的明确反馈，因此本次只能用
两类本地证据判断目标不可达：

```text
地图证据：持续 blocked 且 active-goal A* 不可达
运动证据：里程计在 goal_stall_timeout_s 内没有产生足够接近进展
```

两种情况都必须进入同一个 failed-goal 冷却机制。只触发重新规划而不排除旧目标会
再次选中相同最高分目标，不能算完成了不可达恢复。

当存在其他候选时，Explorer 应增加 generation 并发布替代目标，Planner 随后重新
规划。当不存在其他候选时，Explorer 只能报告 `WAIT_FOR_FRONTIER`；旧轨迹是否取消、
飞机是否悬停属于 Planner/控制器安全接口。本次不扩展该接口，但板端交接必须明确
记录这一残余风险，不能宣称 Explorer 单独保证了悬停。

## 7. 建议的代码修改位置

主要文件：

```text
include/daib_explorer/explorer_core.h
src/explorer_core.cpp
src/explorer_node.cpp
config/explorer.yaml
launch/explorer.launch
test/explorer_core_test.cpp
docs/RUNTIME_VALIDATION.md
README.md
```

重点函数：

```text
ExplorerCore::sanitizeConfig()
ExplorerCore::makeSafeViewpoint()
ExplorerCore::updateDecision()
ExplorerCore::updateGoalStatus()
ExplorerCore::frontierScore() 或拆分后的 information/motion score
ExplorerNode::loadCoreConfig()
ExplorerNode 的状态日志
```

不要改 ROS topic 名称、message 类型或 frame contract。

## 8. 日志要求

当前日志把所有失败都显示成 `0 viewpoints`，无法定位到底是哪一层拒绝。增加每轮
候选拒绝计数，但不要继续拉长 INFO 日志。

至少区分：

```text
clusters_total
rejected_no_viewpoint
rejected_distance
rejected_height_or_geofence
rejected_heading
candidates_scored
```

推荐 INFO 摘要：

```text
frontier=952 clusters=66 candidates=8 reject=40/6/4/8 goal=ACTIVE generation=3
```

详细拒绝原因放在 DEBUG 或独立低频日志中。删除 `loop_escape` 和无效 reachability
候选统计后，不要保留对应的冗余字段。

## 9. 必须补充或更新的测试

至少覆盖以下行为：

1. `allow_periodic_goal_switch=false` 时，新出现的高分 frontier 不改变 active goal。
2. active goal 到达后允许生成下一个目标。
3. 单次障碍更新不换目标，连续达到 blocked confirmation 才允许换。
4. 无人机持续接近目标超过 45 秒也不因绝对时间换点。
5. 连续 15 秒没有至少 0.25 米进展时触发 stalled。
6. blocked 或 stalled 后不能立即重新选择原目标附近的候选。
7. failed-goal 冷却到期后允许重新评估该区域。
8. 发布目标距离不超过 8 米。
9. 发布目标航向变化不超过 120 度。
10. 存在前向候选和反向高信息候选时，不能选择约 180 度反向候选。
11. 只有 1~2 个 voxel 的小 frontier cluster 仍能产生候选。
12. `makeSafeViewpoint()` 理想后退点失败时，保守 fallback 可以返回合规 free voxel。
13. geofence 和 absolute Z 硬边界仍然生效。
14. PVBSM 关闭、返回空结果或正常返回时，基础目标选择都能工作。

现有测试不要删除；确实与被删除参数绑定的测试应改写为新的距离、转向和目标状态
语义。

## 10. Bag/板端验收标准

使用此前能复现 `66 clusters/0 viewpoints` 的 bag。验收时至少观察：

```text
/daib_slam/odom
/daib_slam/planning_cloud
/daib_explorer/frontiers
/daib_explorer/goal
/daib_explorer/generation
/daib_explorer/state
/daib_explorer/planning_cloud
```

通过标准：

- map、frontier、PVBSM 继续增长；
- 有 frontier 的正常场景中 `candidates_scored > 0`；
- 目标与当前位置距离始终在配置范围内；
- 目标相对当前 yaw 不超过 120 度；
- active goal 尚未到达且仍在接近时，generation 不变化；
- 新 frontier 出现不能单独触发换点；
- 达到目标、持续阻塞或持续无进展后，generation 才允许增加；
- 持续阻塞或无进展后，新 generation 不得立即重复发布原失败目标；
- Planner 能收到目标，本任务不要求修改 Planner；
- Orange Pi 上 Explorer 更新耗时没有出现持续性明显回归。

建议从 bag 回放开始，不要直接用实机飞行验证未经回放验证的参数。

## 11. 明确的非目标

本次不要做以下事情：

- 不修改 DAIB-LIVO；
- 不修改 `/cloud_register` 或 PointCloud2 发布修复；
- 不修改 DAIB-Planner；
- 不接入 PX4、XTDrone、DJI OSDK/PSDK；
- 不增加新的全局地图；
- 不删除 PVBSM；
- 不改变 `camera_init` 接口契约；
- 不为了让测试通过而直接取消距离、航向、净空、Z 或 geofence 的硬安全边界；
- 不把目标重新改为每秒周期切换；
- 不 force-push 或重写同学现有主线历史。

## 12. 推荐提交拆分

建议至少拆成两个提交，便于 review 和回退：

```text
1. feat: integrate persistent bounded exploration goals
   - 应用/整理 111c481
   - 目标锁定、geofence、launch 参数、兼容测试

2. fix: align frontier goal policy with flight-tested behavior
   - 8 m 距离上限
   - 120 度转向上限和连续运动代价
   - progress-based stall
   - 放松 frontier 硬过滤
   - 删除 loop escape 和候选 A*
   - 拒绝原因统计及测试
```

提交前应给出：

```text
git diff --check
构建结果
单元测试结果
bag 验收摘要
最终参数表
```

如某个验收项因缺少 ROS/bag/ARM 环境无法执行，必须在交接中明确写出未验证项，
不能把“编译通过”描述成“实机策略已经验证”。
