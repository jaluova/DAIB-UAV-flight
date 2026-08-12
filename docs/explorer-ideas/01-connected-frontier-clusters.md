# 01. 使用 6 邻域 BFS 定义合法 frontier cluster

## 状态

`已实现`

## 想法

每次决策前重新验证当前 frontier，并以 planning voxel 的 6 邻域 BFS 计算连通分量。
连通分量必须至少包含 10 个 voxel，才能成为合法 cluster；1 到 9 个 voxel 视为零散
噪声并拒绝。

```yaml
min_frontier_cluster_cells: 10
```

旧的 `frontier_cluster_size_m` 只保留配置兼容，不再决定分组。

## 动机

原来的 2 m 空间桶会把不连通的 frontier 放进同一组，也可能在桶边界切开连续边界。
BFS 直接表达“frontier 是否真正相连”，阈值 10 则抑制小噪点产生 goal。

## 当前性能

实机约 250 个 frontier 时，cluster 计算约为 1.5 到 2.7 ms。BFS 本来就需要访问完整
连通分量，因此把阈值从 4 调到 10 不会增加算法复杂度。

快速观测 free/frontier 更新时验证过以下调试参数：

```yaml
max_raycasts_per_update: 512
frontier_update_rate_hz: 10.0
frontier_update_budget: 4096
```

它们会增加 CPU 负载，不等于正式部署默认值。

## 验收

- 日志同时给出 `components`、`small_rejected`、`valid` 和 `cluster_ms`；
- 单点和少量噪声不能产生候选；
- 连续墙面边界不会因旧空间桶边界被无故拆开。
