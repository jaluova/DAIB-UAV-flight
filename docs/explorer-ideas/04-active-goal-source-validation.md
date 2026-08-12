# 04. active goal 来源 cluster 失效检查

## 状态

`待实现，缺陷已经实机确认`

## 当前问题

默认 `allow_periodic_goal_switch=false`。一旦存在 active goal，只要尚未 reached、
blocked、stalled 或 timeout，决策函数会在重新聚类前返回。因此即使来源 cluster 已经
消失，旧 goal 仍可能继续被 Bridge 和 Planner 执行。

即使允许周期切换，当前轮没有新 candidate 时，代码仍会保留未失败的旧 goal。

此外 `/daib_explorer/goal` 和 `/daib_ego/goal` 都是 latched topic。只修改内部状态而
不发布显式失效消息，Foxglove 和新订阅者仍会看到旧坐标。

## 想法

- active goal 保存稳定 cluster key、representative frontier 和 generation；
- 每轮 frontier 重验证后检查来源 cluster 是否仍是合法连通分量；
- 来源消失且有替代候选：立即发布新 goal，generation 加一；
- 来源消失且无替代候选：进入 `WAIT_FOR_FRONTIER`；
- 发布显式 `goal_valid=false`，Bridge 收到后停止执行旧目标；
- 清空 `selected_cluster_frontiers`，调试 Marker 发布 `DELETE`。

需要定义短暂 cluster 抖动是否允许一到数帧确认，但不能继续依赖“必须到达目标点才
更新”的旧逻辑。

## 验收

- cluster 消失且没有新候选；
- cluster 消失且存在替代候选；
- cluster 只短暂抖动一帧；
- Bridge 已经转发旧 goal；
- Foxglove 在撤销后不再显示旧 goal 和旧 selected cluster。
