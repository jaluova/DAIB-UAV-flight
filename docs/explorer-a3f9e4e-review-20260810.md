# DAIB-Explorer `a3f9e4e` 审查记录

日期：2026-08-10

审查对象：

```text
仓库：https://github.com/YYY0702/DAIB-Explorer.git
提交：a3f9e4eac517ccf1f25f4bb23e55c4b204437d58
说明：feat: add persistent bounded frontier goal policy
```

本地同步分支：

```text
src/DAIB-Explorer
sync-yyy-main-build-fixes
```

## 已正确实现的部分

- 默认目标距离为 `1.5~8.0 m`；
- 目标航向变化硬上限为 `120 deg`；
- 删除偏爱远目标和 `120~180 deg` loop escape；
- 默认 `allow_periodic_goal_switch=false`；
- 使用 `goal_progress_epsilon_m=0.25` 和
  `goal_stall_timeout_s=15.0` 判断停滞；
- blocked/stalled 目标在 `1.0 m` 范围冷却 `30 s`；
- 单 voxel frontier cluster 可以进入候选；
- known-free path 默认比例降到 `0.5`；
- candidate 阶段不再运行 A*；
- active goal 低频运行 bounded A*；
- 距离和航向采用连续代价；
- 新增按阶段划分的候选拒绝计数；
- 新增持久目标、停滞、冷却、距离、航向和单 cluster 测试。

## 待修问题 1：A* 预算耗尽被当成不可达

位置：

```text
src/explorer_core.cpp:1080-1094
```

当前逻辑：

```text
pathReachable() 因 expansion budget 耗尽返回 false
  -> cached_goal_reachable_ = false
  -> raw_blocked = true
  -> 后续地图更新累计 blocked_streak_
  -> 切换目标
```

虽然代码增加了 `reachability_budget_exhaustions` 计数，但没有阻止预算耗尽参与
blocked 判定。复杂地图或动态预算缩小时，一次不完整搜索可能被解释成目标不可达。

建议把 reachability 结果改为三态：

```text
REACHABLE
UNREACHABLE
UNKNOWN_BUDGET_EXHAUSTED
```

只有明确 `UNREACHABLE` 才能累计 blocked。`UNKNOWN_BUDGET_EXHAUSTED` 只增加诊断
计数，保留当前目标并等待下一次检查。

## 待修问题 2：blocked confirmation 重复使用旧 A* 结果

当前 A* 默认 `2 Hz`，地图更新默认 `10 Hz`。一次 negative A* 结果会被缓存，并在
每个地图更新中继续累计 `blocked_streak_`。因此配置中的 10 次确认通常只需要约
1 秒，并不是 10 次独立 reachability 结论。

建议：

- 只在本轮完成了新的、明确的 `UNREACHABLE` 检查时递增 streak；
- 新检查返回 `REACHABLE` 时清零；
- 返回 `UNKNOWN_BUDGET_EXHAUSTED` 时保持 streak，不递增；
- 直线路径恢复无障碍时立即清零；
- 增加单元测试，验证单次 negative 或 budget exhaustion 不会换目标。

## 待修问题 3：绝对高度和 geofence 遗漏

`111c481` 中已有但 `a3f9e4e` 未包含：

```text
min_goal_z_m
max_goal_z_m
geofence_enabled
geofence_min_x_m / geofence_max_x_m
geofence_min_y_m / geofence_max_y_m
geofence_min_z_m / geofence_max_z_m
```

当前只保留：

```yaml
max_goal_vertical_distance_m: 3.0
```

相对高度约束不能替代绝对飞行边界。如果无人机位置逐步漂高，每一代目标仍可满足
“相对当前位置 3 m”，但任务整体可能越过安全高度。

建议从 `111c481` 手工移植 absolute Z 和可选 geofence，不要恢复该提交中较远目标、
`min_known_free_path_ratio=1.0` 或其他过严候选参数。候选必须同时满足：

```text
相对高度限制
绝对 min/max Z
启用时的 geofence
```

需要恢复对应的 config、launch override、ROS 参数读取和单元测试。

## 观察项：候选仍按 heading tier 预排序

`a3f9e4e` 最终评分使用连续 heading cost，但 cluster 在生成候选前仍按
`0~60 deg`、`60~120 deg` 排序，并在候选达到 `max_safe_viewpoint_candidates` 时停止。
frontier 很多时，第二档候选可能没有进入最终连续评分。

这符合“优先小转向”的保守方向，暂不作为阻塞问题。真实 bag 若出现目标方向过于
单一、合理侧向目标长期没有进入评分，再考虑删除 tier 预排序或为第二档保留固定候选
配额。

## 测试缺口

新增单元测试覆盖了主目标策略，但仍缺少：

1. A* budget exhaustion 不得触发 blocked；
2. blocked streak 只累计独立 definitive checks；
3. absolute Z 和 geofence；
4. cooldown 内存在其他可用 frontier 时必须发布新的 generation；
5. ROS runtime 层的目标持久、stall 和 cooldown 行为；
6. 真实 bag 对原问题 `clusters > 0, viewpoints = 0` 的回归验证。

现有 `RequiresConsecutiveObstacleConfirmation` 最后只检查产生了一个 decision，没有
检查 decision 的 `valid`、`reason` 和 generation。应加强断言，避免其他状态变化让
测试误通过。

## 上板前结论

该提交的总体策略已基本符合目标保持和运动约束要求，但以下两项必须先修：

```text
1. budget exhaustion 不能等价于 unreachable
2. 恢复 absolute Z 和 geofence 安全边界
```

修复后应先通过 Release build、gtest、rostest，再用产生过
`66 clusters/0 viewpoints` 的同一 bag 验证候选拒绝计数和 generation 行为。未完成
这些验证前，不应直接替换板端实飞镜像。

