# DAIB UAV 试飞快速报告

日期：2026-08-18

平台：Orange Pi 5 Max + Livox MID-70 + Intel RealSense D435i

当前验收模式：LIO-only，关闭相机图像处理和 Foxglove

## 当前已验证

- MID-70 `/livox/lidar`：约 10 Hz，单帧约 9984 点。
- D435i `/camera/imu`：约 200 Hz。
- LiDAR/IMU 时间戳无回退，最近邻时间差 p95 约 2.3 ms。
- FAST-LIVO 输出 `/daib_slam/odom`，算法容器健康运行。
- LIO-only 启动脚本最终输出 `[PASS] LIO-only stack is ready`。
- D435i 图像在 LIO-only 模式下不建立活动传输连接；相机只保留兼容性的休眠订阅。

## 飞行前启动

在 Orange Pi 主机执行：

```bash
cd /mnt/huawei_ssd/daib
./scripts/start_lio_only.sh --check-seconds 15
```

ROS Master 由独立的 `deploy-roscore-1` 容器长期运行。启动脚本默认复用该 Master 和
已经运行的传感器驱动容器，只重建算法容器；这样重启算法不会丢失驱动的 ROS 注册，
也不会打断 D435i 的 USB/UVC 会话。只有确认需要重启驱动时才加：

```bash
./scripts/start_lio_only.sh --restart-drivers --check-seconds 15
```

需要启用 D435i 图像参与 FAST-LIVO 时，执行正常 LIVO 模式：

```bash
./scripts/start_livo.sh --check-seconds 15
```

脚本会自动尝试 `chrony` 校时，并保存最后一次有效时间。板子的硬件 RTC 不可用；如果设备刚重启且网络没有 NTP，脚本会尝试用上次有效时间恢复。若恢复失败，先手动设置：

```bash
sudo date -s "YYYY-MM-DD HH:MM:SS"
```

确认出现：

```text
[PASS] LIO-only stack is ready
```

## 飞行数据录制

录包必须在正常 LIVO 启动通过后，从第二个 SSH 终端执行：

```bash
cd /mnt/huawei_ssd/daib
./scripts/record_fast_livo_inputs.sh --min-free-gb 20
```

脚本将 `/livox/lidar`、`/camera/imu` 和
`/camera/color/image_fast_livo` 直接写入：

```text
/mnt/huawei_ssd/bags/fast_livo_real/<日期时间>/
```

它使用 LZ4 压缩、4 GiB 分卷，并在剩余空间达到阈值时安全停止。结束飞行后先按
`Ctrl+C`，等待 `[PASS] Recording finalized` 和 `.bag.active` 消失，再停止容器或关机。
需要自动限制录制时间时可用：

```bash
./scripts/record_fast_livo_inputs.sh --max-minutes 10 --min-free-gb 20
```

2026-08-18 实机验收结果：59.1 秒、12909 条消息、LZ4 后 1.1 GiB；三路平均频率
分别约为 10 Hz、200 Hz 和 8.44 Hz。

## 观察位姿和抖动

当前容器已启动时，可以在 Orange Pi 上执行：

```bash
docker exec deploy-algorithm-1 bash -lc '
  source /opt/ros/noetic/setup.bash
  source /opt/daib_ws/devel/setup.bash
  rostopic echo -n 1 /daib_slam/odom
  rostopic echo -n 1 /daib_slam/degenerate
  rostopic echo -n 1 /daib_slam/degeneracy_score
  rostopic echo -n 1 /daib_slam/lio_runtime_ms
'
```

第一次测试顺序：

1. 桨叶拆除，纯电源静置 2～5 分钟，确认容器没有重启和 USB 重连。
2. 安全固定飞机，电机从怠速逐步增加，观察位姿是否跳变。
3. 第一次只做 0.5～1 m 低空悬停 20～30 秒。
4. 再做小幅平移和原地偏航；不要让飞控依赖这套 SLAM 自动控制。

## 可选：打开 Foxglove 看图像

需要实时图像时执行：

```bash
cd /mnt/huawei_ssd/daib
./scripts/start_flight_stack.sh --check-seconds 15 --camera-rate 6
```

然后在电脑 Foxglove 连接：

```text
ws://<香橙派的Wi-Fi地址>:8765
```

Foxglove 只用于观察，网络卡顿不会直接造成 LIO 漂移。

## Explorer + EGO 仅观察模式

需要先看 Explorer 选点和 EGO 避障路线、但仍由遥控器飞行时执行：

```bash
cd /mnt/huawei_ssd/daib
./scripts/start_explorer_planning_observe.sh --check-seconds 15 --camera-rate 8
```

脚本会启动正常 LIVO、Explorer、`daib_ego_bridge`、EGO-Planner、`traj_server` 和
受限 topic 的 Foxglove Bridge。`traj_server` 的输出被强制改到
`/daib_observe/position_cmd_unconnected`；脚本验证该话题没有订阅者，不启动
MAVROS、PX4 offboard、SDK 或飞行控制器。

Foxglove Fixed Frame 选择 `camera_init`，重点查看：

- `/daib_explorer/goal`
- `/daib_explorer/selected_cluster_frontiers`
- `/daib_explorer/planning_cloud`
- `/drone_0_ego_planner_node/goal_point`
- `/drone_0_ego_planner_node/optimal_list`
- `/drone_0_ego_planner_node/grid_map/occupancy_inflate`

停止全部算法、驱动和 Foxglove：

```bash
./scripts/stop_daib_stack.sh
```

## 当前功能边界

常规飞行一键脚本实际启动的是：

- MID-70 驱动。
- D435i IMU 驱动。
- FAST-LIVO 定位、建图和位姿输出。
- 可选 Foxglove 图像转发。

`start_explorer_planning_observe.sh` 会额外启动 Explorer、EGO-Planner 和
`daib_ego_bridge`，但仍然**没有启动**：

- PX4/MAVROS offboard 控制和自动避障。
- SDK/控制器轨迹执行链路。

因此观察模式可以“手动飞 + 看 Explorer 目标 + 看 EGO 路线”，但不能把当前命令
当成自动探索或自动避障飞行命令。后续要实现自动探索，需要单独接通 Planner →
飞控控制器，并完成台架、急停和仿真验收。
