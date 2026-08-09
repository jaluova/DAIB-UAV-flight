# Indoor3 中 PX4 Odom、FAST-LIVO2 与 EGO-Planner 联调总结

日期：2026-08-03

## 1. 文档目的

本文记录当前 `ros1-rviz` 容器中的完整仿真链路、已经完成的修改、逐终端启动
方法、已观察到的故障，以及下一阶段推荐架构。

当前实验目标不是直接宣布完成无 GPS 闭环，而是分离验证以下能力：

1. PX4/MAVROS 是否能提供稳定的控制反馈里程计。
2. FAST-LIVO2 是否能稳定处理仿真 Livox、IMU 和相机数据。
3. EGO-Planner 是否能使用 PX4 odom 和雷达点云完成局部避障。
4. SLAM 坐标漂移是否会污染 EGO 的障碍物和轨迹。
5. 后续如何把控制、局部规划、全局建图和 RViz 可视化解耦。

## 2. 当前结论

当前系统存在两个不同层面的问题，不能只归因于 EGO 或只归因于 SLAM。

### 2.1 当前轨迹扭曲的首要原因

EGO 当前混用了两套状态：

```text
无人机位置：PX4 local odom，通常稳定
障碍点云：FAST-LIVO2 使用自身位姿转换到 camera_init
```

当 FAST-LIVO2 位姿发生漂移或跳变时，点云会相对稳定的 PX4 无人机位置发生
“瞬移”。EGO 会把这种坐标跳变理解为障碍物突然移动，继而重新规划出扭曲、
绕远或短时不连续的轨迹。

因此，当前重新规划时出现的轨迹异常，第一瓶颈是坐标和数据源不一致。

### 2.2 FAST-LIVO2 本身也存在稳定性问题

已经观察到以下现象：

- Gazebo 实时率约为 `0.45-0.53`。
- `/scan` 间歇出现空点云。
- 有效雷达约束有时只有十几个到几十个。
- 退化分数多次接近零。
- 室外宽街、平行结构和大平面容易发生几何退化。
- 启用 VIO 后相机处理会增加 Gazebo 和 FAST-LIVO2 的计算负载。
- 重新规划引起的转弯、加速和 yaw 变化可能进一步暴露退化或时序问题。

所以，坐标问题修复后，仍然需要单独处理传感器空帧、仿真实时率、VIO 标定、
时间同步和几何退化。

### 2.3 当前仍不是真正的无 GPS 闭环

此前验证的 PX4 参数为：

```text
EKF2_AID_MASK = 1
EKF2_HGT_MODE = 0
```

这表示 PX4 水平位置仍使用 GPS 辅助，高度主要使用气压计。在没有重新验证
PX4 外部视觉注入和 EKF2 参数前，当前 `PX4 odom + EGO` 只能作为稳定对照组，
不能作为比赛最终的无 GPS 方案。

## 3. 环境与工作区

容器：

```text
ros1-rviz
```

主要路径：

```text
/root/PX4_Firmware
/root/XTDrone
/root/daib_fastlivo_ws
/root/daib_ego_ws
/root/daib_env.sh
```

所有节点必须连接容器本机 ROS Master：

```text
ROS_MASTER_URI=http://127.0.0.1:11311
ROS_HOSTNAME=127.0.0.1
ROS_IP 未设置
```

不得连接开发板 ROS Master：

```text
http://192.168.0.2:11311
```

## 4. 图形界面准备

在宿主机执行一次：

```bash
export DISPLAY=:0
xhost +SI:localuser:root
```

每个容器终端进入方式：

```bash
docker exec -it ros1-rviz bash
```

每个容器终端执行：

```bash
source /root/daib_env.sh
export DISPLAY=:0
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP
```

测试结束后可在宿主机撤销 X11 授权：

```bash
DISPLAY=:0 xhost -SI:localuser:root
```

不要使用 `xhost +`，因为它会对所有客户端关闭 X11 访问控制。

## 5. Indoor3 仿真模型

已创建：

```text
/root/PX4_Firmware/launch/indoor3_my.launch
```

对应仓库文件：

```text
scripts/indoor3_my.launch
```

配置为：

```text
world: $(find px4)/Tools/sitl_gazebo/worlds/indoor3.world
vehicle: iris
sdf: iris_realsense_livox
spawn position: (0, 0, 0)
spawn attitude: (0, 0, 0)
```

world 使用 `$(find px4)` 定位，不再依赖额外的
`mavlink_sitl_gazebo` ROS package 路径。

## 6. FAST-LIVO2 仿真配置

仿真启动文件：

```text
/root/daib_fastlivo_ws/src/fast_livo/launch/mapping_avia_sim.launch
```

输入：

```text
LiDAR: /scan
IMU:   /iris_0/imu_gazebo
Image: /iris_0/stereo_camera/left/image_raw
```

相机标定对应 XTDrone 仿真相机：

```text
image width:  752
image height: 480
```

`mapping_avia_sim.launch` 已将 `img_en` 默认值改为 `1`，所以直接启动会启用
VIO：

```bash
roslaunch fast_livo mapping_avia_sim.launch rviz:=false
```

临时关闭视觉进行 A/B 测试：

```bash
roslaunch fast_livo mapping_avia_sim.launch rviz:=false img_en:=0
```

成功启用 VIO 后应持续出现类似日志：

```text
Get image
[ VIO ] Raw feature num
[ VIO ] Update Visual Map
```

相关 FAST-LIVO2 提交：

```text
ee1deac  publish lidar-corrected IMU-rate odometry
b4674be  add LIO-only XTDrone simulation launch
37fcb30  use XTDrone camera calibration in simulation
538ef4f  enable simulated VIO by default
```

## 7. 当前逐终端启动流程

用户要求保留每个组件一个终端的启动方式，不使用组合 launch。

### 7.1 终端 1：PX4、Gazebo、MAVROS 和 ROS Master

```bash
source /root/daib_env.sh
export DISPLAY=:0
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP

roslaunch px4 indoor3_my.launch
```

该命令会自动启动 ROS Master，不需要额外执行 `roscore`。

### 7.2 终端 2：XTDrone communication

```bash
source /root/daib_env.sh
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP

cd /root/XTDrone/communication
python3 multirotor_communication.py iris 0
```

### 7.3 终端 3：FAST-LIVO2

FAST-LIVO2 启动时，无人机应静止在出生点：

```bash
source /root/daib_env.sh
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP

roslaunch fast_livo mapping_avia_sim.launch rviz:=false
```

### 7.4 终端 4：当前 PX4 odom frame 适配器

```bash
source /root/daib_env.sh
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP

rosrun ego_planner px4_odom_camera_init.py
```

当前适配器订阅：

```text
/iris_0/mavros/local_position/odom
/daib_slam/imu_odom
```

输出：

```text
/daib_px4/odom_camera_init
```

已经观察到的启动日志：

```text
PX4/SLAM start alignment accepted at 0.181 m.
Publishing /daib_px4/odom_camera_init.
```

注意：`accepted` 只表示误差小于当前 `0.5 m` 阈值，不表示已经消除这
`0.181 m` 误差。

### 7.5 终端 5：EGO 手动规划

```bash
source /root/daib_env.sh
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP

roslaunch ego_planner daib_manual.launch \
  use_sim_time:=true \
  odom_topic:=/daib_px4/odom_camera_init \
  cloud_topic:=/daib_slam/planning_cloud \
  world_frame:=camera_init \
  traj_server_pose_cmd_topic:=/xtdrone/iris_0/cmd_pose_enu \
  max_vel:=0.3 \
  max_acc:=0.5 \
  odom_timeout_s:=0.6 \
  cloud_timeout_s:=1.0
```

该模式下，RViz `2D Nav Goal` 默认保持无人机当前高度。

### 7.6 终端 6：RViz

```bash
source /root/daib_env.sh
export DISPLAY=:0
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP

rviz -d /root/fast_livo2.rviz
```

### 7.7 终端 7：键盘控制，可选

```bash
source /root/daib_env.sh
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP

cd /root/XTDrone/control/keyboard
python3 multirotor_keyboard_control.py iris 1 vel
```

实测键盘节点会以 `10 Hz` 持续发布：

```text
/xtdrone/iris_0/cmd_vel_flu
```

XTDrone communication 没有控制权仲裁。键盘 Twist 和 EGO Pose 会共同修改
communication 内的控制目标。可以用键盘进行起飞前人工操作，但发送 EGO
目标前应停止键盘节点，否则当前测试不是单一 EGO 控制源。

## 8. 启动后验证

确认 ROS Master：

```bash
echo "$ROS_MASTER_URI"
rosnode list
```

期望：

```text
http://127.0.0.1:11311
```

检查传感器与状态频率：

```bash
rostopic hz /scan
rostopic hz /iris_0/imu_gazebo
rostopic hz /iris_0/stereo_camera/left/image_raw
rostopic hz /iris_0/mavros/local_position/odom
rostopic hz /daib_slam/odom
rostopic hz /daib_slam/imu_odom
rostopic hz /daib_slam/planning_cloud
rostopic hz /daib_px4/odom_camera_init
```

检查 frame：

```bash
rostopic echo -n 1 /iris_0/mavros/local_position/odom/header
rostopic echo -n 1 /daib_slam/odom/header
rostopic echo -n 1 /daib_slam/planning_cloud/header
rostopic echo -n 1 /daib_px4/odom_camera_init/header
```

当前预期：

```text
PX4 odom:        map
SLAM odom:       camera_init
planning cloud:  camera_init
adapted PX4 odom: camera_init
```

检查 EGO 是否真的订阅了适配 odom：

```bash
rostopic info /daib_px4/odom_camera_init
```

`Subscribers` 应包含：

```text
/drone_0_ego_planner_node
```

检查执行链：

```bash
rostopic info /xtdrone/iris_0/cmd_pose_enu
rostopic info /iris_0/mavros/setpoint_raw/local
```

期望：

```text
/drone_0_traj_server 发布 cmd_pose_enu
/iris_0_communication 订阅 cmd_pose_enu
/iris_0_communication 是 setpoint_raw/local 的唯一发布者
```

## 9. 当前 planning cloud 到底是什么

`/daib_slam/planning_cloud` 不是原始 `/scan`，也不是完整累计全局地图。

当前生成过程：

```text
/scan
  -> IMU 运动畸变补偿
  -> feats_undistort
  -> 体素降采样
  -> feats_down_body
  -> 使用 FAST-LIVO2 的 rot、pos 和雷达-IMU外参转换
  -> world_lidar(camera_init)
  -> 均匀抽样，最多保留2048点
  -> /daib_slam/planning_cloud
```

所以它可以称为“经过处理的当前帧雷达点云”：

- 障碍物几何来自当前雷达扫描。
- 点云经过 IMU 去畸变。
- 点云经过体素降采样。
- 点数被限制为最多 `2048`。
- 点的世界坐标依赖 FAST-LIVO2 当前位姿。
- 它不是不受 SLAM 影响的一手机体系点云。

相关实现：

```text
src/DAIB-LIVO/src/LIVMapper.cpp:574  体素降采样
src/DAIB-LIVO/src/LIVMapper.cpp:638  转到SLAM世界坐标
src/DAIB-LIVO/src/LIVMapper.cpp:707  生成planning_cloud
src/DAIB-LIVO/src/LIVMapper.cpp:724  frame_id=camera_init
src/DAIB-LIVO/config/avia.yaml:99    max_planning_points=2048
```

## 10. EGO 对 SLAM 的真实依赖

工程上需要分开理解三个层次。

### 10.1 局部规划和避障

EGO 局部规划需要：

```text
连续可靠的odom
当前局部障碍物
统一且正确的坐标系
```

它不要求完整的全局 SLAM 地图，也不要求回环检测。深度相机、当前雷达扫描或
短时滚动点云都可以作为局部障碍输入。

### 10.2 全局自主探索

DAIB-Explorer 或其他 frontier 探索模块需要：

```text
全局地图
已探索/未探索区域
全局一致的机器人位置
```

如果 SLAM 全局地图损坏，无人机可能仍在移动和局部避障，但探索覆盖率、
返回起点、重复区域判断和全局目标选择将不再可信。

### 10.3 无 GPS 飞行控制

PX4 位置控制需要连续状态估计。无 GPS 时，这个状态通常来自 LIO、VIO、光流、
外部视觉或其他定位源。

所以准确结论是：

```text
EGO局部规划不强依赖完整SLAM地图；
EGO仍强依赖可靠odom；
全局探索依赖地图；
无GPS控制依赖可靠的非GPS状态估计。
```

## 11. 为什么当前 frame 适配器不是最终方案

`px4_odom_camera_init.py` 当前只做：

```text
读取PX4 odom数值
检查启动时PX4与SLAM位置差小于阈值
把header.frame_id从map改成camera_init
保持位置、速度和姿态数值不变
```

它没有处理：

- 启动时的平移误差。
- PX4 `map` 和 SLAM `camera_init` 的 yaw 差。
- `base_link` 与 FAST-LIVO2 IMU参考点之间的固定外参。
- 飞行过程中逐渐增长的漂移。
- SLAM重启或位姿跳变。
- PX4 odom和雷达帧之间的时间差。

EGO GridMap 会严格要求 odom 和 cloud 的 `frame_id` 与配置 frame 相同，所以
适配器能消除 frame 检查报错，但不能保证两个话题的数值真的处于同一坐标系。

因此它只适合起点、坐标轴和 yaw 已经近似重合的短距离仿真对照，不应作为
最终飞行架构。

## 12. 当前轨迹扭曲的故障链

当前故障可以按以下顺序解释：

```text
无人机转弯、加速或接近障碍
  -> EGO触发重新规划
  -> 传感器视角变化且计算负载上升
  -> FAST-LIVO2退化、延迟或位姿跳变
  -> planning_cloud随SLAM位姿整体跳动
  -> PX4 odom仍保持稳定
  -> EGO认为障碍物相对无人机突然移动
  -> 新轨迹扭曲、绕远或短时不连续
  -> RViz以camera_init为Fixed Frame时整个显示同时失真
```

重新规划本身不会直接修改 FAST-LIVO2 状态。它更可能通过运动状态和计算负载
暴露已有的 SLAM 问题，随后错误点云又反过来污染规划。

## 13. 推荐的近期架构

当前仿真中，PX4 odom 是更稳定的局部参考。因此推荐让 PX4 `map` 成为控制、
局部规划和主 RViz 的统一坐标系。

目标数据链：

```text
/daib_slam/planning_cloud(camera_init)
/daib_slam/odom(camera_init -> imu body)
/iris_0/mavros/local_position/odom(map -> base_link)
                         |
                         v
同步动态点云转换节点
                         |
                         v
/daib_px4/planning_cloud(map)

EGO:
  odom_topic  = /iris_0/mavros/local_position/odom
  cloud_topic = /daib_px4/planning_cloud
  world_frame = map

RViz Fixed Frame = map
```

此时不再需要 `px4_odom_camera_init.py`。

## 14. 动态点云转换公式

采用记号 `T_A_B` 表示把 B 坐标系中的点转换到 A 坐标系。

简化公式：

```text
T_map_camera_init(t)
  = T_map_body(PX4, t)
  * inverse(T_camera_init_body(SLAM, t))
```

更严格地考虑 PX4 `base_link` 与 FAST-LIVO2 IMU参考点的固定外参：

```text
T_map_camera_init(t)
  = T_map_base_link(PX4, t)
  * T_base_link_imu
  * inverse(T_camera_init_imu(SLAM, t))
```

点云转换：

```text
p_map = T_map_camera_init(t_cloud) * p_camera_init
```

关键要求：

1. `/daib_slam/planning_cloud` 与 `/daib_slam/odom` 使用相同雷达时间戳。
2. PX4 odom必须插值到点云时间戳，不能使用回调时的最新位姿。
3. 使用完整3D旋转和平移，不能只处理yaw或只减XYZ。
4. 必须包含 `base_link` 到SLAM IMU参考点的固定外参。
5. 输入时间差、非有限值和过大跳变必须触发丢帧或安全状态。

当前 FAST-LIVO2 已给 `/daib_slam/odom` 和 planning cloud 设置相同的
`last_lio_update_time`，适合进行严格同步。

## 15. 为什么动态转换能改善局部避障

当前 planning cloud 是当前帧雷达点经过 SLAM 位姿变换后的结果。假设同一帧
SLAM odom和点云使用了同一个错误刚体位姿，那么：

```text
SLAM错误位姿进入planning_cloud
SLAM错误位姿的逆进入T_map_camera_init
```

两者在动态转换中会相互抵消，最终点云主要由当前雷达几何、传感器外参和PX4
位姿决定。

它能消除刚体坐标跳变对当前局部点云的污染，但不能修复：

- 错误的点云去畸变。
- IMU bias导致的扫描内部形变。
- 空雷达帧。
- 错误的相机或雷达外参。
- 全局SLAM地图已经产生的重影和扭曲。

## 16. 另一种实现：直接发布机体系点云

FAST-LIVO2 内部已经有去畸变、降采样后的 `feats_down_body`。另一种方案是新增：

```text
/daib_slam/planning_cloud_body
```

其 frame 可以定义为雷达、IMU或明确的传感器机体系。随后使用 PX4 odom 和
静态传感器外参将它转换到 `map`。

优点：

- 数据含义直接。
- 不需要先乘SLAM位姿再求逆。
- SLAM世界位姿不会进入局部障碍物坐标。

缺点：

- 需要修改FAST-LIVO2发布接口。
- 必须准确区分雷达坐标、IMU坐标和PX4 base_link。
- 必须重新验证点云时间戳和运动畸变补偿参考时刻。

近期最小实现可以先做同步动态转换桥；长期接口可以改为明确的机体系规划点云。

## 17. RViz 与 frame 设计

`camera_init` 名称中的 camera 不表示当前相机坐标。它是 FAST-LIVO2 启动时
建立的固定世界参考。

建议主 RViz 使用：

```text
Fixed Frame = map
```

主视图显示：

```text
PX4实际位置和轨迹
EGO规划轨迹
转换后的局部规划点云
目标点
局部占据图
```

SLAM调试内容单独显示或使用第二个RViz：

```text
FAST-LIVO2 /path
/cloud_registered
/Laser_map
camera_init相关Marker
```

当SLAM健康检查失败时，可以停止发布 map 到 camera_init 的可视化变换，使
RViz明确显示“无可用transform”，而不是继续展示已经错误的地图。

仅仅把RViz Fixed Frame从 `camera_init` 改成 `map`，但不转换点云和轨迹，不能
解决问题，只会得到transform缺失或新的坐标错位。

## 18. SLAM健康检查建议

至少监控：

```text
/daib_slam/degenerate
/daib_slam/degeneracy_score
/daib_slam/lio_runtime_ms
/daib_slam/odom
/daib_slam/imu_odom
/daib_slam/planning_cloud
/scan
/iris_0/imu_gazebo
```

建议检查：

- 连续退化帧数量。
- 单帧位置和yaw跳变。
- odom消息最大周期。
- receipt time减header time的延迟。
- 雷达空帧比例。
- 每帧输入点数和有效约束数量。
- LIO运行时间相对雷达周期的占比。
- VIO图像积压和图像时间戳顺序。

安全策略应区分：

```text
短时退化：保持当前轨迹或降速
持续退化：停止生成新探索目标
odom跳变：EGO急停并清空局部地图
点云丢失：EGO急停
SLAM重启：旧frame和旧地图全部失效，重新对齐
```

## 19. 已有性能证据

此前38.5秒对比bag中：

| 指标 | FAST-LIVO2 | PX4 GPS/EKF |
|---|---:|---:|
| 平均频率 | 14.97 Hz | 30.01 Hz |
| 最大消息周期 | 364 ms | 40 ms |
| 平均消息延迟 | 77.9 ms | 5.9 ms |
| 最大相邻位置步长 | 0.203 m | 0.032 m |

对齐后的水平误差均值约 `0.049 m`，p95约 `0.102 m`，说明 FAST-LIVO2 的
低频尺度和总体位移并非完全不可用。主要风险是短时抖动、延迟和不均匀更新，
而这些问题恰好会明显影响局部规划和控制。

## 20. SLAM稳定性排查顺序

不要同时修改地图、坐标、VIO、控制器和EGO参数。建议按以下顺序：

### 阶段 A：传感器与LIO静态验证

```text
无人机不上锁
不启动EGO
img_en=0
检查scan、IMU、空帧、退化分数和odom静止漂移
```

### 阶段 B：VIO A/B验证

在相同地图和相同运动下分别测试：

```bash
roslaunch fast_livo mapping_avia_sim.launch rviz:=false img_en:=0
roslaunch fast_livo mapping_avia_sim.launch rviz:=false img_en:=1
```

比较：

```text
odom跳变
退化持续时间
图像延迟
CPU占用
雷达空帧比例
```

如果启用VIO明显变差，优先检查相机-雷达外参、图像时间戳、相机内参和CPU，
而不是继续调EGO。

### 阶段 C：低动态飞行

建议先使用：

```text
max_vel = 0.2-0.3 m/s
max_acc = 0.3-0.5 m/s^2
短距离同高度目标
固定或缓慢yaw
```

当前 Pose 控制链丢失了 EGO `PositionCommand` 中的速度和加速度前馈，因此
不适合一开始就进行高速或急转弯测试。

### 阶段 D：动态点云转换后复测

确认障碍物在PX4 `map`中不会因SLAM位姿跳变而瞬移，再判断剩余轨迹异常是否
来自SLAM点云几何、EGO参数或执行控制器。

## 21. 无GPS最终架构边界

当前动态点云转换方案能让局部规划使用统一坐标，但它不会凭空产生无GPS定位。

最终目标应为：

```text
FAST-LIVO2或其他无GPS定位源
  -> MAVROS external vision/odometry
  -> PX4 EKF2
  -> PX4连续local odom
  -> EGO和控制器
```

同时：

```text
当前雷达帧
  -> 去畸变
  -> PX4连续odom坐标
  -> EGO滚动局部地图
```

如果 PX4 odom最终也由 FAST-LIVO2提供，那么SLAM前端真正崩溃后，PX4只能依靠
IMU进行短时预测，不能无限期继续自主探索。此时必须设计：

- 外部视觉创新门限。
- SLAM位姿跳变拒绝。
- 短时失效悬停。
- 重定位或重新初始化。
- 无法恢复时安全降落。

当前仿真中SLAM崩溃后仍能飞，是GPS/PX4 EKF对照链的结果，不代表无GPS实机
具备同样能力。

## 22. 控制层后续问题

当前执行链：

```text
EGO PositionCommand
  -> traj_server降级为geometry_msgs/Pose
  -> XTDrone communication
  -> MAVROS PositionTarget
  -> PX4
```

Pose链会丢失：

```text
velocity
acceleration
yaw rate
```

它适合作为 `0.3-0.5 m/s` 的低速连通性基线，不是最终高质量轨迹控制器。

长期应使用直接消费 `quadrotor_msgs/PositionCommand` 的成熟控制器，保留速度和
加速度前馈，并确保它是唯一 MAVROS setpoint 发布者。该工作应在坐标和SLAM
输入稳定后单独验收，不能与无GPS EKF切换同时调试。

## 23. 建议录包

复现重新规划导致的异常时，至少录制：

```bash
rosbag record \
  /scan \
  /iris_0/imu_gazebo \
  /iris_0/stereo_camera/left/image_raw \
  /iris_0/mavros/local_position/odom \
  /daib_slam/odom \
  /daib_slam/imu_odom \
  /daib_slam/planning_cloud \
  /daib_slam/degenerate \
  /daib_slam/degeneracy_score \
  /daib_slam/lio_runtime_ms \
  /daib_px4/odom_camera_init \
  /daib_ego/position_cmd \
  /xtdrone/iris_0/cmd_pose_enu \
  /iris_0/mavros/setpoint_raw/local
```

分析时重点确认事件顺序：

```text
EGO命令变化
SLAM退化
SLAM odom跳变
planning cloud跳变
EGO重新规划
PX4实际运动
```

这样才能判断是控制动作先触发SLAM问题，还是SLAM输入先污染规划。

## 24. 安全退出

停止任何控制、PX4或Gazebo进程前，先确认：

```bash
rostopic echo -n 1 /iris_0/mavros/state
```

必须为：

```text
armed: False
```

建议按以下顺序停止：

```text
EGO
odom/cloud适配节点
FAST-LIVO2
keyboard
XTDrone communication
PX4/Gazebo/MAVROS/ROS Master
```

此前出现的：

```text
Failsafe enabled: no RC and no offboard
mc_pos_control invalid setpoints
Gazebo PhysicsEngine shared_ptr assertion
```

前两项与控制输入丢失或无效有关；最后一项出现在强制关闭Gazebo的清理阶段，
不是找不到launch文件或SLAM算法崩溃的直接原因。

## 25. 已完成修改与状态

FAST-LIVO2 子仓库已提交：

```text
ee1deac  IMU频率odom
b4674be  mapping_avia_sim.launch
37fcb30  XTDrone相机标定
538ef4f  仿真默认启用VIO
```

EGO 子仓库已提交：

```text
0a33e3c  EGO使用高频IMU odom接口
157f67a  traj_server恢复Pose输出
```

主仓库已提交：

```text
093a52e  IMU odom与点云规划接口文档
f47cbb9  本机容器环境配置
```

当前已创建但尚未作为最终架构提交/验收的内容：

```text
scripts/indoor3_my.launch
ego-planner launch/daib_px4_odom_slam.launch
ego-planner scripts/px4_odom_camera_init.py
```

用户当前选择逐终端启动，所以组合
`daib_px4_odom_slam.launch` 不作为日常启动入口。

## 26. 推荐下一步实施顺序

1. 实现按时间戳同步的 `planning_cloud(camera_init) -> map` 动态转换节点。
2. EGO改为直接使用PX4原始odom和转换后的map点云。
3. RViz主视图切换到PX4 `map`，SLAM调试视图与主视图分离。
4. 删除当前frame改名适配器在正式链路中的作用。
5. 使用Indoor3分别进行 `img_en=0/1` 的SLAM稳定性A/B测试。
6. 记录重新规划前后的完整bag并确认故障发生顺序。
7. 坐标和局部点云稳定后，再处理控制器速度/加速度前馈。
8. 最后恢复PX4外部视觉融合并执行真正的无GPS验收。

核心原则是：

```text
控制使用连续odom；
局部规划使用同一odom坐标下的当前传感器；
全局地图允许慢速修正或重定位；
全局地图跳变不能直接传给局部控制和避障。
```
