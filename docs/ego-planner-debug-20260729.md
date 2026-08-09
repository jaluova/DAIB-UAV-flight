# ego-planner 调试记录 (2026-07-29)

## 修复项

### 1. 地图可视化 bug（occupancy 始终为空）

**问题**: `pose_type=2` 时 `cloudCallback` 只写 `occupancy_buffer_inflate_`，但 `publishMap()` 读的是 log-odds 的 `occupancy_buffer_`（从未写入），导致 rviz 里 `/drone_0_ego_planner_node/grid_map/occupancy` 永远是 `width: 0`。

**修复** (`grid_map.cpp`): `publishMap()` 在 `!flag_use_depth_fusion` 时改从 `occupancy_buffer_inflate_` 读取并发布。

### 2. 轨迹显示：控制点折线 → 平滑 B 样条

**问题**: rviz 里 `optimal_list` 显示的是控制点连线（折线段），优化成功/失败都看起来一样差。

**修复**:
- `ego_replan_fsm.cpp`: 优化成功时对 B 样条以 0.05s 步长采样，调用新的 `displaySampledList()`，只画 LINE_STRIP、无球体
- `planner_manager.cpp`: 优化失败时不推折线到 `optimal_list`，不再冒充轨迹
- `planning_visualization.h/.cpp`: 新增 `displaySampledList()` 方法；全部硬编码 frame_id 从 `world`/`map` 统一改为 `camera_init`

### 3. cloud_timeout 放宽

**配置** (`daib_single_uav.launch`): `cloud_timeout` 1.0 → 2.0s，RK3588 板载高负载下 1s 太紧。

### 4. 障碍物 inflation 调整

**配置** (`daib_single_uav.launch`): `obstacles_inflation` 0.5 → 0.3，0.25m 分辨率室外场景 0.5 偏大。

### 5. 其他配置调整

| 改动 | 旧值 | 新值 | 原因 |
|---|---|---|---|
| map_size_x/y | 80 | 100 | 更大飞行空间 |
| map_size_z | 8 | 30 | |
| ground_height | -3 | -5 | |
| virtual_ceil_height | 4.75 | 25 | |
| manual_goal min_z | -2.5 | -5 | 与 launch 一致 |
| manual_goal max_z | 4.5 | 25 | |
| distinctive_trajs | false | true | 多轨迹并行优化，提高成功率 |
| initial_plan_trials | 3 | 10 | 首条轨迹更多尝试 |
| ctrl_pt_dist | 0.5 | 0.4 | 更密的控制点 |
| lambda_smooth | 1.0 | 1.2 | 轨迹更圆滑 |
| lambda_collision | 0.8 | 0.5 | 稀疏点云下不跟幻影障碍较劲 |
| lambda_feasibility | 0.2 | 0.1 | |

**bridge 同步修改** (`bridge.yaml`): z 限、max_goal_distance 同步放宽；`bridge_node.cpp` reject 日志增强。

## 当前状态

### 已确认工作
- `ego_planner_node` 编译成功（100%，0 错误）
- `occupancy_inflate` 正常（~10311 点）
- `occupancy` 修复后不再为 `width: 0`
- `optimal_list` 显示为平滑 B 样条曲线

### 当前阻塞：EMERGENCY_STOP 刷屏

**现象**: planner 每 50ms 打印 `Depth Lost! EMERGENCY_STOP`，FSM 卡在 `EMERGENCY_STOP` 状态。

**根因**: `updateOccupancyCallback` 在 `pose_type=2` 模式下检查 `has_cloud_`：
1. 如果 `has_cloud_` 从未被设 → 触发 timeout
2. 如果 cloud 间隔 > `cloud_timeout` (2.0s) → 触发 timeout

planner 订阅 `/daib_explorer/planning_cloud`，但 cloud 来源可能断了。需要排查 explorer 是否在转发 SLAM 的 cloud。

### daib_ego_bridge

- bridge 状态首次显示 `WAIT_EXPLORER`，`ready=False` 未发布
- 手动 `rostopic pub /daib_explorer/ready` 后 bridge 开始工作
- goal 正确转发到 `/daib_ego/goal`（`x=51.75, y=-27.75, z=-0.75`）
- **问题**: z 值偏低（camera_init 坐标系地面约 z=0），可能穿地

### 未完成

- **执行链**: `traj_server` 仍然被注释掉（缺 `PositionCommand.h`），XTDrone 端 `/xtdrone/iris_0/cmd_*` 没有发布者
- **cloud 来源排查**: 需要确认 `/daib_explorer/planning_cloud` 是否有数据

## 编译部署注意事项

板子（openEuler 24.03 ARM64）上容器内编译的特殊情况：

1. **手工消息头**: `traj_utils/{Bspline,DataDisp,MultiBsplines}.h` 必须保留在容器内，不能被覆盖
2. **workspace setup.bash**: 重建 CMakeCache 后必须显式传入 `-DCMAKE_PREFIX_PATH=/opt/ros/noetic`，否则 `source ~/catkin_ws/devel/setup.bash` 不链入 ROS
3. **CATKIN_WHITELIST_PACKAGES**: 之前缓存过 `daib_ego_bridge`，重建时必须清掉
4. 源码在容器内路径为 `/root/catkin_ws/src/ego_planner_swarm/planner/`，宿主机的 `~/catkin_ws/` 未挂载到容器
5. 部署流程：rsync 到板子 `/data/ego-planner-swarm/` → 容器内 cp 到 workspace → 编译

## 下一步

1. 排查 `planning_cloud` 来源（explorer 是否在转发）
2. 解决 EMERGENCY_STOP 后验证规划是否成功
3. 打通执行链（`PositionCommand.h` + `traj_server`）
