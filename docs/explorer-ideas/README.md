# Explorer 想法索引

本目录只记录 Explorer 的设计想法和实施状态。每个想法单独成文，避免把已经实现的
行为、已经确认的缺陷和仍在讨论的方案混在一起。

状态定义：

- `已实现`：源码中已经存在，仍需以当前镜像或源码版本为准；
- `待实现`：方案已经形成，但尚未修改代码；
- `待设计`：方向已经明确，关键算法或接口仍需继续讨论。

## 清单

- [x] [01. 使用 18 邻域 BFS 定义合法 frontier cluster](01-connected-frontier-clusters.md)
  - `已实现`。cluster 允许棱连接但不允许纯角点连接，且至少包含 10 个 planning voxel。
- [x] [02. 发布最终入选 cluster 的 frontier](02-selected-cluster-frontiers-topic.md)
  - `已实现`。点云 topic 只显示实际产生当前 goal 的完整 frontier cluster。
- [ ] [03. Explorer 全局 exploration memory](03-global-exploration-memory.md)
  - `待实现`。独立记录任务期间曾被 LiDAR 稳定观察的区域，避免局部地图裁剪后重复探索。
- [ ] [04. active goal 来源 cluster 失效检查](04-active-goal-source-validation.md)
  - `待实现`。来源 cluster 消失时换目标或撤销旧目标，并向 Bridge 显式发布无效状态。
- [ ] [05. 水平飞行 goal 与最终观察 yaw](05-level-flight-goal-and-observation-yaw.md)
  - `待设计`。goal 优先位于当前 odom.z 的 XY 平面，yaw 表示到达后的观察朝向。
- [ ] [06. 按完整 cluster 和 viewpoint 信息收益评分](06-cluster-information-gain-scoring.md)
  - `待设计`。不再只使用一个 representative frontier 的局部邻居数代表整个 cluster。
- [ ] [07. 拆分候选拒绝原因和数值诊断](07-candidate-rejection-diagnostics.md)
  - `待实现`。将 distance 拆成 too-near/too-far，并发布候选的实际距离和各项约束结果。
- [ ] [08. Explorer 分层可视化](08-layered-explorer-visualization.md)
  - `待设计`。分别显示 cluster、viewpoint、拒绝原因、评分和 goal 状态机，定位问题所在层级。

## 推荐实施顺序

1. 先实现入选 cluster 点云，它能直接验证当前 goal 的来源。
2. 用相同的 cluster 身份实现 active goal 失效检查和显式撤销。
3. 实现 exploration memory 的更新与统计，第一阶段不参与过滤。
4. 验证记忆稳定后，再接入历史区域的 cluster 过滤。
5. 调整 goal 高度、最终 yaw 和完整 cluster 信息收益评分。
6. 在每一步同步补充对应的结构化诊断与可视化。
