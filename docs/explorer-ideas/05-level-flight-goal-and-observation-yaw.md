# 05. 水平飞行 goal 与最终观察 yaw

## 状态

`待设计`

## 当前行为

goal 的 xyz 来自三维 safe-viewpoint 搜索。z 只要求与当前 odom.z 的差不超过 3 m，
并没有优先保持当前高度。

goal 姿态的 roll/pitch 为零，但 yaw 当前计算为：

```text
当前位置 -> goal viewpoint 的行进方向
```

它不是无人机到达 goal 后面向 frontier 或 unknown 的期望观察方向。下游 EGO 当前也
主要消费 goal xyz，实际飞行 yaw 还需要核对 Planner 和控制接口的语义。

## 想法

- 默认在当前 `odom.z` 的 XY 飞行平面搜索 viewpoint；
- 仅当水平面没有安全候选时，才考虑受限的 z 调整；
- goal roll/pitch 保持为零；
- goal yaw 表示从 viewpoint 面向 cluster/unknown 的最终观察方向；
- 区分 `travel_yaw` 和 `observation_yaw`，避免一个字段承担两种语义。

## 待定问题

- 当前高度是每次决策时的 odom.z，还是任务启动时的固定巡航高度；
- 允许的高度回退范围和地面/天花板安全约束；
- Bridge、EGO 和最终控制器是否能完整消费 observation yaw；
- 飞行途中 yaw 如何从 travel direction 过渡到 final observation yaw。

## 验收

- 普通室内候选优先与当前飞行高度一致；
- goal 箭头在 viewpoint 处指向被选 cluster 的 unknown 一侧；
- 不因三维 frontier 噪声产生无必要的上升或下降目标；
- Planner 和控制器中的 yaw 语义与 Explorer 一致。
