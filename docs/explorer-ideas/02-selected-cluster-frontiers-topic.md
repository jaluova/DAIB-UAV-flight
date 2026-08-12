# 02. 发布最终入选 cluster 的 frontier

## 状态

`已实现`

## 想法

新增调试输出：

```text
/daib_explorer/selected_cluster_frontiers
类型：sensor_msgs/PointCloud2
坐标系：与 goal 相同，当前为 camera_init
```

该点云只包含最终获胜 candidate 对应的完整 BFS frontier cluster，不包含其他合法
cluster，也不是根据 goal 坐标事后反推出来的附近点。

## 发布语义

- 发布新 goal 时，同步发布其来源 cluster；
- goal 保持期间，点云保持与该 goal 的 generation 对应；
- 换 goal 时，完整替换为新 cluster；
- goal 撤销或进入 `WAIT_FOR_FRONTIER` 时，发布空点云；
- 当前版本尚不主动检测来源 cluster 是否已消失；该行为属于想法 04，完成后也应
  在失效时发布空点云；
- topic 可以 latch，但必须用空点云主动清除旧显示。

## 内部状态

候选需要保存 cluster 索引或稳定 cluster key。最终选择后，Core 保存：

```cpp
std::vector<VoxelKey> selected_frontier_cluster_;
uint64_t selected_cluster_generation_;
```

Node 只在 cluster generation 与 goal generation 一致时发布非空点云；不一致时
发布空点云并记录错误。该身份信息后续也可用于 active goal 来源验证。

## 动机

现有 `/daib_explorer/frontiers` 只显示全部 frontier，无法回答“当前 goal 到底由哪一个
cluster 产生”。这个 topic 是检查 cluster、viewpoint 和 goal 关系的最直接证据。

## 验收

- 点云中的每个点都属于最终获胜的同一个 BFS 连通分量；
- 点云、goal 和 generation 同步切换；
- 没有有效 goal 时，新订阅者也不会看到旧 cluster；
- 来源 cluster 的主动失效清理待想法 04 实现；
- Foxglove 中可以同时区分全部 frontier、入选 cluster 和 goal。
