# ego-planner-swarm 编译跳过的包

DAIB 单机模式不需要以下包，在 `ros1_dev` 容器里用 `CATKIN_IGNORE` 跳过编译。

## CATKIN_IGNORE（共 12 个）

### uav_simulator 仿真（9 个）
| 包 | 路径 | 原因 |
|---|---|---|
| rviz_plugins | uav_simulator/Utils/rviz_plugins | 缺 rviz，板上不需要 |
| odom_visualization | uav_simulator/Utils/odom_visualization | 依赖 quadrotor_msgs encode_msgs |
| multi_map_server | uav_simulator/Utils/multi_map_server | 依赖 quadrotor_msgs |
| map_generator | uav_simulator/map_generator | 仿真用 |
| mockamap | uav_simulator/mockamap | 仿真用 |
| so3_control | uav_simulator/so3_control | 仿真动力学 |
| so3_quadrotor_simulator | uav_simulator/so3_quadrotor_simulator | 仿真用 |
| fake_drone | uav_simulator/fake_drone | 仿真用 |
| local_sensing | uav_simulator/local_sensing | 仿真传感器 |

### planner 辅助（3 个）
| 包 | 路径 | 原因 |
|---|---|---|
| rosmsg_tcp_bridge | planner/rosmsg_tcp_bridge | TCP 桥接，DAIB 不需要 |
| waypoint_generator | uav_simulator/Utils/waypoint_generator | 仿真用 |
| drone_detect | planner/drone_detect | 集群探测 |

## 源码修改

| 文件 | 改动 | 原因 |
|---|---|---|
| quadrotor_msgs/CMakeLists.txt | 注释 `decode_msgs`/`encode_msgs` 编译 + 清空 `LIBRARIES` | 缺 OutputData.h |
| traj_utils/include/traj_utils/{Bspline,DataDisp,MultiBsplines}.h | 手工生成（含序列化方法） | 本板 ROS 消息生成器全局失效 |
| plan_manage/CMakeLists.txt | 注释 `traj_server` | 缺 quadrotor_msgs/PositionCommand.h |
| plan_manage/include/plan_manage/ego_replan_fsm.h | `sed` 清理重复 typedef | 之前手工补丁残留 |

## 关键：消息头文件

本板（openEuler 24.03 ARM64）ROS1 catkin `generate_messages()` 失效，3 个消息头需手工维护：
- `traj_utils/include/traj_utils/Bspline.h`
- `traj_utils/include/traj_utils/DataDisp.h`
- `traj_utils/include/traj_utils/MultiBsplines.h`

**每次 `git pull` 或整包覆盖代码时需重新复制这些文件**，否则编译会报 `fatal error: traj_utils/Bspline.h: No such file or directory`。

### 部署脚本应包含
```bash
cp /path/to/backup/traj_utils/{Bspline.h,DataDisp.h,MultiBsplines.h} \
   ~/catkin_ws/src/ego_planner_swarm/planner/traj_utils/include/traj_utils/
```
