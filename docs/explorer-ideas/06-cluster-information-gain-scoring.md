# 06. 按完整 cluster 和 viewpoint 信息收益评分

## 状态

`待设计`

## 当前问题

每个 cluster 会生成一个 safe viewpoint，但最终信息分主要来自距离 cluster 中心最近的
一个 `representative frontier`：只统计它的 6 邻域 unknown、occupied 和访问次数。

cluster 大小只用于最小阈值和候选处理顺序，没有直接进入最终得分；viewpoint 到达后
实际能看到多少 unknown 也没有计算。因此小 cluster 的一个局部点可能压过更有价值的
大 cluster。

## 想法

评分对象应是“完整 cluster + 实际 safe viewpoint”，而不是单个代表点。候选信息收益
至少考虑：

- cluster 的有效 frontier voxel 数量；
- 从 viewpoint 可见的 frontier 数量或比例；
- viewpoint 视场内可观测 unknown 的数量；
- cluster 空间跨度，避免单纯奖励重复密集 voxel；
- 历史 exploration memory 的新颖比例；
- 距离、转向、已知 free 路径和失败目标冷却仍作为代价或硬约束。

需要对 cluster 大小做归一化或饱和处理，防止一个巨大边界永久压制其他方向。

## 建议诊断字段

```text
cluster_cells
visible_frontier_cells
visible_unknown_cells
historical_observed_ratio
distance_cost
heading_cost
total_score
rank
```

## 验收

- 同等距离和安全条件下，能观察更多新 unknown 的 viewpoint 得分更高；
- 密集重复 voxel 不会线性无限抬高得分；
- 每个分项可在日志或结构化调试消息中解释；
- 固定 rosbag 下排序可重复。
