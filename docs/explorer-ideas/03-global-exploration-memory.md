# 03. Explorer 全局 exploration memory

## 状态

`已实现，默认观察模式`

## 想法

Explorer 自己维护一份任务期全局观测记忆，不依赖 SLAM voxel 或 PVBSM。它只表达
“过去是否稳定观察过这个区域”，用于避免局部 `map_` 裁剪后把旧区域重新当成新的
探索目标。

推荐初始参数：

```yaml
exploration_memory_enabled: true
exploration_memory_voxel_size_m: 1.0
exploration_memory_min_observations: 3
exploration_memory_max_range_m: 20.0
frontier_history_probe_distance_m: 4.0
frontier_history_probe_step_m: 1.0
frontier_history_observed_ratio: 0.7
```

## 已实现的更新规则

- LiDAR 射线经过的粗 voxel 记为 `observed-free`；
- 射线终点记为 `observed-surface`；
- 终点后方保持 unknown；
- 同一帧先去重，每个 cell 每帧最多累计一次；
- 至少被 3 个不同帧观察后才算稳定 observed；
- 任务期间只在内存中单调增长；节点每 10 秒写入 `/tmp` 快照，正常新任务清空，
  watchdog 故障恢复加载快照。

实现复用滚动占据图已经选出的预算内 LiDAR 射线，不增加 FAST-LIVO 点云输入，也不
重新遍历全部原始点。超过记忆半径的射线只记录半径内的经过空间，不把远端点误记为
surface。

## cluster 历史判断

cluster 通过 BFS 和大小检查后，从其 unknown 一侧向外采样 1、2、3、4 m：

- 稳定 observed 比例大于等于 0.7：判为历史区域并拒绝；
- 多数位置从未 observed：保留为新探索边界。

frontier 自身不参与采样，因为边界 cell 本来就已被看到。

当前提供两个独立开关：

```yaml
exploration_memory_enabled: true
exploration_memory_filter_enabled: true
```

当前默认已将 `exploration_memory_filter_enabled` 设为 `true`，达到
`frontier_history_observed_ratio` 的历史 cluster 不再进入 viewpoint/goal 选择。
`valid_cluster_frontiers` 仍保留这些几何上合法的 cluster，便于对比过滤效果。

## 安全边界

这份记忆不能证明一个位置现在仍然 free，不能用于碰撞检测、墙面净空或替代 Planner
地图。它只影响探索新颖性。若以后存在较大的回环位姿修正，还需要处理历史记忆在
`camera_init` 下的坐标一致性。

## 分阶段验收

1. 确认日志中的 `cells/stable` 基本单调增长；
2. 检查 `checked/observed/rejected/probes`，验证历史 cluster 被抑制；
3. 验证首次进入保留、离开返回抑制；
4. 墙后遮挡不得误判，单帧噪声不得达到稳定 observed 门槛；
5. 正常新任务清空快照，watchdog 恢复保留记忆，滚动占据图和 Planner 安全语义保持不变。
