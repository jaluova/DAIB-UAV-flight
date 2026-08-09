# Indoor3可靠局部坐标与无GPS闭环实施记录

日期：2026-08-03

## 坐标职责与正式数据链

正式局部规划坐标为PX4连续本地`map`，FAST-LIVO2的`camera_init`只属于建图域：

```text
mission_map  未来全局探索/重定位坐标
map          PX4连续本地规划与控制坐标
base_link    PX4机体参考点
laser_livox  去畸变雷达帧
camera_init  FAST-LIVO2内部世界坐标
```

已经实现的数据链为：

```text
/daib_slam/planning_cloud_lidar (laser_livox, <=2048 points)
 + /iris_0/mavros/local_position/odom (map -> base_link)
 -> planning_cloud_px4_bridge (timestamp interpolation)
 -> /daib_px4/planning_cloud (map)
 -> EGO (map)
 -> /daib_ego/position_cmd
 -> geometric_controller
```

`px4_odom_camera_init.py`和`daib_px4_odom_slam.launch`只保留为历史A/B对照，正式
入口是`ego_planner/indoor3_px4_local.launch`。

## 已实施内容

### 阶段A：静态坐标与外参

- `fast_livo/config/avia_xtdrone_sim.yaml`在基础`avia.yaml`之后覆盖XTDrone外参。
- FAST-LIVO2发布去畸变、体素降采样的当前雷达帧到
  `/daib_slam/planning_cloud_lidar`，时间戳为`last_lio_update_time`，frame为
  `laser_livox`，不应用SLAM世界位姿。
- 原`/daib_slam/planning_cloud`继续保留为`camera_init`世界点云，仅用于A/B。
- `scripts/validate_indoor3_extrinsics.py`自动检查外参数值、旋转行列式和三个已知轴
  投影方向。

首次飞行前仍必须现场完成静止TF检查，并在`img_en:=0`通过后用已知几何验证相机
投影；外参未通过时不得启用VIO或EGO飞行。

### 阶段B：可靠局部规划闭环

`planning_cloud_px4_bridge`实现了2秒odom缓存、位置线性插值、四元数slerp和：

```text
p_map = T_map_base_link(t_cloud) * T_base_link_lidar * p_lidar
```

它严格检查`laser_livox`、`map`和`base_link`，要求点云时间被odom包围，插值区间
不超过0.15秒，最多等待0.20秒。零/乱序时间戳、frame错误、空/全非有限点云、
odom间隙、0.5米位置跳变、30度yaw跳变和输入陈旧都会使
`/daib_px4/planning_input_valid=false`。状态话题区分：

```text
WAIT_ODOM WAIT_CLOUD NORMAL INVALID_FRAME INVALID_STAMP
ODOM_GAP ODOM_JUMP EMPTY_CLOUD STALE_INPUT
```

EGO在首次`NORMAL`前拒绝目标但允许各节点并行启动。首次有效后，任何无效输入、
odom超时或cloud超时都会永久锁存`EMERGENCY_STOP`：清除目标和活动轨迹，按最后
有效规划odom只发布一次悬停B样条，且进程内禁止自动恢复。操作员必须重启EGO。

正式launch默认`img_en=0`、`max_vel=0.3 m/s`、`max_acc=0.5 m/s^2`、RViz固定
frame为`map`：

```bash
roslaunch ego_planner indoor3_px4_local.launch
```

### 阶段C：控制执行链

`patches/lio-drone-250-controller-safety.patch`在固定LIO-Drone-250提交上增加：

- 所有状态显式初始化，`enable_sim`默认false，不自动切OFFBOARD或解锁；
- 直接读取position、velocity、acceleration、yaw和yaw rate；
- 拒绝非有限命令，0.20秒`PositionCommand`超时后锁定当前悬停点；
- 修复两个服务回调返回值和动态调参`Kv_y`赋值；
- 移除100 Hz stdout输出。

构建与独立启动：

```bash
./scripts/build_lio_controller_ws.sh
roslaunch ego_planner indoor3_geometric_controller.launch
```

启动控制器前必须停止XTDrone communication节点，并用`rostopic info`确认只有
`/iris_0/geometric_controller`发布MAVROS setpoint。控制器仍需依次通过无桨、
1米起飞、30秒悬停、命令中断和AUTO.LAND仿真验收后才能批准正式飞行。

## 自动验证

当前自动测试覆盖：

- odom位置插值、四元数slerp、完整3D点变换、位置/yaw跳变；
- frame错误、零/乱序时间戳、空云、全NaN和逐点NaN删除；
- 无插值区间、过大odom间隙、输入陈旧和输出时间戳/frame；
- EGO启动等待、故障后单次悬停发布权限和不可自动恢复；
- XTDrone三组静态外参数值与已知轴方向。

验证命令：

```bash
./scripts/validate_indoor3_extrinsics.py
catkin_make run_tests
```

## 尚未宣告通过的门禁

代码和单元/ROS合约测试通过不等于Indoor3仿真验收。以下项目必须使用实际Gazebo
时序、bag和参数快照完成，未通过不得进入下一阶段：

1. 有效雷达帧输出率不少于90%，桥处理延迟p95小于50毫秒。
2. 静止障碍物质心抖动p95小于0.10米，整帧跳动不超过0.20米。
3. 注入SLAM世界位姿跳变时，新PX4点云不跳；odom/cloud中断后0.20秒内悬停。
4. 只有一个MAVROS setpoint发布者，低速短目标无frame拒绝和控制源竞争。
5. 分别保存`img_en=0/1`的空帧、odom周期/延迟/跳变、退化持续时间、帧内形变、
   LIO/VIO耗时和Gazebo实时率；退化标志本身不直接丢弃有效局部点云。

## 真正无GPS阶段

当前PX4 `map`仍可含GPS辅助，因此阶段A-C只建立可靠局部闭环，不构成无GPS成果。
后续必须把FAST-LIVO2 odom经固定初始对齐和跳变拒绝注入PX4 EKF，依次验证静止、
起飞、悬停、2米往返和降落。只有PX4 local odom连续后才接回DAIB-Explorer：全局
目标属于`mission_map`，执行前转换到PX4 `map`；SLAM重启/重定位必须作废旧任务，
持续退化时停止探索并悬停，无法恢复时安全降落。
