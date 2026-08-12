# 07. 拆分候选拒绝原因和数值诊断

## 状态

`待实现`

## 当前问题

日志中的 `rejected_distance` 同时包含：

```text
distance < min_goal_distance_m
distance > max_goal_distance_m
```

因此看到 `distance/8` 时，无法判断八个候选全部太近、全部太远，还是两者混合。其他
拒绝计数也只给总数，没有候选对应的实际数值。

## 想法

至少拆分以下统计：

```text
rejected_too_near
rejected_too_far
rejected_vertical
rejected_heading
rejected_known_path
rejected_failed_goal
rejected_no_viewpoint
```

每个决策周期额外记录候选距离、垂直差和 heading 的 min/max，必要时为调试 topic 发布
逐候选结构化信息。正常高频日志仍只输出汇总，避免刷屏。

## 动机

拒绝原因决定应该修改地图、viewpoint 生成还是参数。如果没有数值，容易把“全部候选在
8 m 外”误判成 cluster 没有生成，或者盲目放宽安全约束。

## 验收

- 各拆分计数之和与对应原始候选数量一致；
- 没有候选时可以从一行汇总判断卡在哪个约束；
- 固定 rosbag 下统计稳定；
- 诊断功能对正常规划耗时影响可以忽略。
