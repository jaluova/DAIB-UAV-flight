# 完整探索流程录包方案

本文档用于记录一次真实的 FAST-LIVO + Explorer + EGO + DJI 控制链路，目标是让
Foxglove 展示和后续分析都对应当时实际发生的轨迹。

## 为什么不能只录输入

算法重启或单独回放传感器输入时，FAST-LIVO 初始化、ROS 消息时序、Explorer 选点、
EGO 重规划时刻以及飞行器实际响应都可能变化。因此重新运行算法得到的轨迹不一定等于
原飞行轨迹。

要展示“这一次飞行到底发生了什么”，必须在实际运行时录制算法输出和控制指令；原始
传感器只用于定位问题和尝试重算。

## 话题分层

### A. 实际结果，必须录制

这些话题构成一次探索结果的时间线，优先级最高：

```text
/daib_slam/odom
/path
/cloud_registered
/daib_explorer/goal
/daib_explorer/selected_cluster_frontiers
/drone_0_ego_planner_node/goal_point
/drone_0_ego_planner_node/optimal_list
/daib_ego/position_cmd
/psdk/dji_command_xyz_yaw
```

建议同时保留以下状态和安全诊断话题（如果当前版本存在）：

```text
/daib_explorer/state
/daib_explorer/generation
/daib_explorer/frontiers
/daib_explorer/planning_cloud
/psdk/velocity_direction_dji_world
/psdk/odom_corrected
/daib_ego/bridge_state
/daib_ego/accepted_generation
```

其中：

- `/cloud_registered` 是实际 FAST-LIVO 输出的当前帧点云，Foxglove 中用于观察地图和
  色彩点云；不要用它替代实际的控制结果。
- `/daib_explorer/goal` 和 `selected_cluster_frontiers` 说明 Explorer 为什么选择
  当前方向。
- `goal_point` 和 `optimal_list` 说明 EGO 实际接受了什么目标、生成了什么局部轨迹。
- `/psdk/dji_command_xyz_yaw` 是发送给 DJI bridge 的最终 `{x,y,z,yaw}`，用于核对
  坐标转换、限速、超时归零和遥控器夺权。

### B. 原始输入，建议录制

```text
/livox/lidar
/camera/imu
/camera/color/image_fast_livo
```

`/camera/color/image_fast_livo` 是 FAST-LIVO 实际消费的约 10 Hz 图像。首选它，不要
默认加入 30 Hz 的 `/camera/color/image_raw`，否则包体会显著增大。

只有在需要逐帧检查 D435i 原始画面、曝光或图像同步时，才额外录制：

```text
/camera/color/image_raw
```

## 推荐录制档位

### 展示实际探索结果（默认）

保留 A 层全部话题，加上 B 层三个输入话题。大话题建议限频：

- `/livox/lidar`：原生频率或按磁盘空间限频。
- `/camera/imu`：原生频率，便于分析振动和时间同步。
- `/camera/color/image_fast_livo`：约 10 Hz。
- `/cloud_registered`：2--5 Hz 足够 Foxglove 展示；若需要分析每帧点云再保留原频率。
- `/path`、Marker、状态和指令话题：保持原生频率。

这是一档最适合“展示完整探索流程”的录包，重点是保存实际目标切换、局部轨迹和
DJI 指令，而不是保存每一帧的大型可视化数据。

### 传感器问题排查

在默认档位基础上增加 `/camera/color/image_raw`，并尽量保留原生
`/cloud_registered`。该档位只用于短时间排查，开始前确认板端 CPU、SSD 和剩余空间。

当前 `scripts/record_fast_livo_inputs.sh` 只负责录制 FAST-LIVO 输入，不能替代完整
探索结果录制。

## 手工录制前检查

在香橙派算法容器中确认话题实际存在，名称以现场输出为准：

```bash
docker exec daib-algorithm bash -lc '
  source /opt/ros/noetic/setup.bash
  source /opt/daib_ws/devel/setup.bash
  rostopic list | grep -E \
    "cloud_registered|daib_slam/odom|daib_explorer|optimal_list|goal_point|position_cmd|psdk"
'
```

如果使用独立 ROS Master 容器，把 `daib-algorithm` 换成能够访问同一个
`ROS_MASTER_URI` 的算法容器。

## 录制命令模板

下面命令应在算法容器内执行，并根据检查结果删除现场不存在的话题。建议输出到挂载的
SSD 目录，使用分卷避免单个 bag 过大：

```bash
docker exec -it daib-algorithm bash -lc '
  source /opt/ros/noetic/setup.bash
  source /opt/daib_ws/devel/setup.bash
  session=/bags/exploration_$(date +%Y%m%d_%H%M%S)
  mkdir -p "$session"
  rosbag record --lz4 --split --size=4096 --buffsize=512 \
    -O "$session/exploration_run" \
    /livox/lidar \
    /camera/imu \
    /camera/color/image_fast_livo \
    /daib_slam/odom \
    /cloud_registered \
    /path \
    /daib_explorer/goal \
    /daib_explorer/frontiers \
    /daib_explorer/selected_cluster_frontiers \
    /daib_explorer/planning_cloud \
    /daib_explorer/state \
    /daib_explorer/generation \
    /drone_0_ego_planner_node/goal_point \
    /drone_0_ego_planner_node/optimal_list \
    /daib_ego/position_cmd \
    /psdk/dji_command_xyz_yaw \
    /psdk/velocity_direction_dji_world \
    /psdk/odom_corrected
'
```

实际使用时应把 `-O` 改成带有本次日期时间的唯一前缀，并确认 `/bags` 已映射到 SSD。
结束录制后必须等待 rosbag 正常退出，确认没有 `.bag.active` 文件，再停止算法或断电。

## 元数据和复现要求

每次录制目录旁边保存一个文本文件，至少记录：

```text
开始/结束时间（含时区）
香橙派和妙算地址
算法、驱动、Foxglove bridge 容器镜像标签
git commit 或工作区版本
实际录制话题列表和限频设置
起飞前的坐标系、速度限制、yaw 限制
是否启用 DJI API 输出
```

展示视频、Foxglove 截图和问题分析都引用同一批 bag。重新启动算法后产生的新轨迹应
另存为新 bag，不能覆盖原始实飞包。

## 回放原则

- 只看实际飞行结果：直接回放并显示 A 层话题，不启动会重新发布同名控制话题的算法。
- 要复现算法行为：停止实时驱动后再用 B 层输入回放，并把结果写入新的命名空间或新
  bag，明确标注为“重算轨迹”。
- 不要把重算后的 `optimal_list` 当成原飞行时的局部轨迹。
