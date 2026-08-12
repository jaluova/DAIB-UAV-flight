# 08. Explorer 分层可视化

## 状态

`待设计，部分基础 topic 已存在`

## 想法

按照决策流水线分层发布调试信息，使问题能够定位到 occupancy、frontier、cluster、
viewpoint、评分、goal 状态机中的具体一层。

建议层次：

```text
/daib_explorer/planning_cloud
/daib_explorer/frontiers
/daib_explorer/selected_cluster_frontiers
/daib_explorer/debug/frontier_clusters
/daib_explorer/debug/viewpoints
/daib_explorer/debug/rejected_viewpoints
/daib_explorer/debug/view_rays
/daib_explorer/debug/goal_status
```

## 显示约定

- 全部 frontier 使用低亮度小点；
- selected cluster 使用固定高亮颜色和较大点；
- 通过筛选的 viewpoint 使用球体；
- rejected viewpoint 按 distance、vertical、heading、known-path、cooldown 固定着色；
- view ray 连接 viewpoint 与 cluster centroid；
- Marker ID 使用稳定 cluster key，消失时显式发布 `DELETE`；
- goal status 显示 generation、距离、最佳历史距离、progress age、blocked streak、A* 和
  cooldown。

## 原则

调试输出应按需启用或只在存在订阅者时构建，不能让完整 Marker 生成占用正常飞行的
主要 CPU 预算。结构化评分数据与可视化 Marker 可以共用同一份候选诊断结果。

## 验收

- 能判断异常 goal 是来自错误 frontier、错误分组、错误 viewpoint 还是错误评分；
- cluster 和 Marker 颜色、ID 在相邻周期保持稳定；
- cluster 或 goal 消失后没有残留 Marker；
- 关闭调试订阅时不会产生明显额外计算。
