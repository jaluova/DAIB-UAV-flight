# 当前唯一运行基线：sync_yyy

更新时间：2026-08-12

## 基线声明

从本日期起，Orange Pi 实机功能测试、启动命令、参数判断、问题分析和后续修改，
全部以 `sync_yyy` 主线及当前板端算法镜像为准：

```text
DAIB-UAV       sync-yyy-main-build-fixes @ 本文所在提交
DAIB-LIVO      sync-yyy-main-build-fixes @ 58b3af5
DAIB-Explorer  sync-yyy-main-build-fixes @ 68e300c
DAIB-Planner   main / sync build fixes   @ e6f50a6

algorithm image:
192.168.218.119:5050/daib-algorithm:openeuler-arm64
image id: b56cd5581f60
```

上述镜像早于 `DAIB-LIVO@58b3af5`，不包含本节新增的 launch 覆盖入口和 batch2 外参。
在新算法镜像发布并记录新 image ID 前，板端旧镜像仍按旧接口使用；不能仅因源码已合入
就向旧镜像传 `vio_img_point_cov`。

镜像标签将来可能被重新推送。一次实验记录必须同时写明镜像标签和 image ID；只写
`openeuler-arm64` 不能唯一确定测试内容。

## 不再作为当前依据的内容

以下内容只保留作历史记录，不能直接复制为当前启动命令或用于判断当前行为：

- `feature/gpsless-cleanup`、`feature/gpsless-pipeline` 及其镜像；
- 名称含 `gpsless-cleanup-*` 的容器和脚本；
- `dist/yyy-src-20260810` 等旧源码归档；
- 本地子模块中未提交的修改；
- 旧文档中与上述内容绑定的 launch 参数和整链路启动命令。

若旧文档与当前镜像、当前子模块提交或实际 `roslaunch` 文件冲突，以当前镜像内文件
和上述提交为准，并修正文档，不用旧命令迁就当前代码。

## FAST-LIVO 当前启动接口

当前源码主线 `mapping_mid70_d435i.launch` 声明以下参数：

```text
rviz
use_camera
image_rate
vio_img_point_cov
```

真实传感器测试使用：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch \
  rviz:=false \
  use_camera:=true \
  vio_img_point_cov:=100
```

`vio_img_point_cov` 默认值为 `100`。launch 在加载 YAML 后覆盖 ROS 参数
`/vio/img_point_cov`，随后 `laserMapping` 启动并读取该值，因此命令行传值会进入 VIO
EKF。启动后验证实际值：

```bash
rosparam get /vio/img_point_cov
```

该参数只在节点初始化时读取；改变数值需要停止并重新启动 `laserMapping`，不能依靠
运行中的 `rosparam set` 刷新内部值。

## 当前分层测试原则

1. 使用真实 MID-70、D435i 和 IMU，不默认播放 bag。
2. roscore、驱动、Foxglove 和手动算法容器保持独立生命周期。
3. 算法容器保持 `sleep infinity`，由操作者手动执行 `roslaunch`。
4. 先单独验证 SLAM，再验证 Explorer，之后才启动 Planner。
5. Explorer frontier 基线测试先关闭 PVBSM scoring 和动态预算。
6. 每次只改变一个模块或一组明确参数，并记录镜像 ID、命令和 ROS 参数值。

## Explorer free/frontier 默认配置

实机观察中，默认配置已固定为以下经过验证的平衡参数，free 空间和 frontier 的变化
速度比旧的 `64` 条射线、`2 Hz / 512` frontier 更新更及时：

```yaml
planning_output_radius_m: 12.0
planning_sensor_range_m: 20.0
max_raycasts_per_update: 128
frontier_update_rate_hz: 10.0
frontier_update_budget: 2048
goal_evaluation_rate_hz: 4.0
frontier_evaluation_budget: 2400
```

这组参数现在就是默认 `explorer.yaml`，直接启动 Explorer 即可：

```bash
roslaunch daib_explorer explorer.launch \
  pvbsm_memory_enabled:=false \
  pvbsm_scoring_enabled:=false
```

启动日志应显示 `budgets=128 rays/2048 frontier`。如果板端 LIO EMA 持续超过负载阈值，
Explorer 自带的动态预算会进一步降低探索工作量。

## 2026-08-12 实机发现：来源 cluster 消失后旧 goal 仍有效

连通 cluster 测试镜像：

```text
192.168.218.119:5050/daib-algorithm:sync-yyy-frontier-connected6-20260812-arm64
image id / registry digest:
sha256:0d7b676d0aa6c0bb0882cfab1f4fe48d43c0fda1f928efe5c44d1645f14bdc6d
```

实机确认：当前 active goal 的来源 frontier cluster 消失后，只要 goal 尚未 reached、
blocked、stalled 或 timeout，Explorer 仍把旧 goal 保持为有效。默认
`allow_periodic_goal_switch=false` 会在重新聚类和候选验证前直接返回；即使打开周期
切换，当前实现找不到新 candidate 时仍会保留尚未被判失败的旧 goal。

这是算法状态问题，不只是 Foxglove 显示问题。另外 `/daib_explorer/goal` 和
`/daib_ego/goal` 都是 latched topic；即使后续在 Explorer 内撤销 goal，若没有显式
有效性协议或 Marker `DELETE`，Foxglove 和新订阅者仍会看到最后一条旧坐标。

预定修复：

1. active goal 保存稳定 cluster 身份或 representative frontier；
2. 每轮重新聚类后验证来源 cluster，消失时立即撤销或替换；
3. 没有替代候选时进入 `WAIT_FOR_FRONTIER`，不继续执行旧 goal；
4. 增加显式 `goal_valid=false`，Bridge 收到后停止执行旧目标；
5. 调试 Marker 对撤销的 goal 发布 `DELETE`。

验收必须覆盖：cluster 消失且没有新候选、cluster 消失且有替代候选、cluster 暂时
抖动、Bridge 已转发旧 goal 四种场景。

## 2026-08-13 cluster 连通规则和最小阈值

frontier 合法性继续使用 planning voxel 的 6 邻域；cluster BFS 单独使用 18 邻域，
允许通过棱相邻的 frontier 连通，但不合并仅在角点接触的 voxel。合法 cluster 至少
包含 10 个 voxel，因此配置为：

```yaml
min_frontier_cluster_cells: 10
```

BFS 本来就会访问整个连通分量，提高阈值不增加算法复杂度；日志中的
`small_rejected` 现在表示大小为 1 到 9 的连通分量数量。

## Explorer 全局 exploration memory

为避免局部 `map_` 在 40 m 外裁剪后把旧区域重新当成新 frontier，Explorer 维护
一份独立于 SLAM voxel/PVBSM 的任务期全局观测记忆。该记忆由 Explorer 已有 LiDAR
raycast 同步更新，不受 12 m planning-cloud 输出裁剪和 40 m 局部地图裁剪影响。

推荐数据结构：

```cpp
struct ExplorationCell
{
  uint8_t free_observations;
  uint8_t surface_observations;
};

std::unordered_map<VoxelKey, ExplorationCell, VoxelKeyHash>
    exploration_memory_;
```

每帧更新规则：

1. 用 odom 提供射线原点，LiDAR 点提供射线终点；
2. 射线经过的粗体素记为 observed-free，终点记为 observed-surface；
3. 终点后方保持 unknown，不写入记忆；
4. 使用每帧 `frame_free_cells` 和 `frame_surface_cells` 去重，同一 cell 每帧最多加 1；
5. 观测计数采用 `uint8_t` 饱和累加，至少 3 个不同帧才算稳定 observed；
6. 任务期间只增不减；正常新任务清空，watchdog 故障恢复从 `/tmp` 快照恢复，不写 NVMe。

建议初始参数：

```yaml
exploration_memory_enabled: true
exploration_memory_voxel_size_m: 1.0
exploration_memory_min_observations: 3
exploration_memory_max_range_m: 20.0
exploration_memory_filter_enabled: true
frontier_history_probe_distance_m: 4.0
frontier_history_probe_step_m: 1.0
frontier_history_observed_ratio: 0.7
```

cluster 通过 BFS 和最小大小检查后，从中心沿 unknown 方向的 1、2、3、4 m 查询该
记忆。大部分采样点稳定 observed 时判为历史区域并拒绝；大部分从未 observed 时保留。
frontier 所在 cell 不参与判断，因为边界自身必然已被看到。

该记忆只表示“过去看过”，不能证明“现在仍 free”，因此只用于抑制重复探索，不能
替代局部 occupancy、墙面净空检查或 Planner 碰撞地图。若以后加入大幅回环位姿修正，
还需处理 `camera_init` 下历史 coverage 的坐标一致性。

SLAM、Explorer、Planner 的实际数据消费过程和逐层可视化方法见
[`sync-yyy-pipeline-debug-guide-20260812.md`](sync-yyy-pipeline-debug-guide-20260812.md)。

Explorer 后续想法已经拆分为独立条目，统一索引见
[`explorer-ideas/README.md`](explorer-ideas/README.md)。
