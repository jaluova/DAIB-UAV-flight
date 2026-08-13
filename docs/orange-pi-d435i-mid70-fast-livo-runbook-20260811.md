# Orange Pi 5 Max + D435i + MID-70 + FAST-LIVO2 实机运行手册

更新日期：2026-08-11

> **当前基线提示（2026-08-12）**：本文保留硬件、驱动和历史排障记录；涉及算法
> 镜像、容器、launch 参数和模块启动顺序时，必须以
> [`CURRENT_SYNC_YYY_BASELINE.md`](CURRENT_SYNC_YYY_BASELINE.md) 为准。当前所有功能
> 测试只走 `sync_yyy` 主线。

## 1. 文档目的

本文汇总 2026-08-11 在 Orange Pi 5 Max 上打通 Intel RealSense D435i、
Livox MID-70、ROS Noetic、FAST-LIVO2 和 Foxglove 的实机过程。

本文重点记录：

- 最终确认有效的硬件、内核、网络、容器和 ROS 配置。
- 每个故障的表象、根因和修复方法。
- 已经通过 rosbag 验证的数据链路。
- 传感器时间戳检查器实际检查了什么，以及它不能证明什么。
- 将 ROS Master、驱动、Foxglove 和算法解耦后的手动工作流。
- 当前仓库脚本中仍需修复的已知问题。

不要把本文中的历史失败命令直接用于生产。标为“已验证”的结果来自本次实机输出；
标为“待复验”的部分是根据已验证镜像设计的最终操作方式，但尚未收到完整的板端验收输出。

## 2. 已确认环境

| 项目 | 值 |
|---|---|
| 板卡 | Orange Pi 5 Max / RK3588 |
| 架构 | `aarch64` |
| 宿主系统 | Orange Pi 1.0.0 / Ubuntu 22.04.4 Jammy |
| 内核 | `6.1.43-rockchip-rk3588` |
| 内存 | 7.7 GiB RAM、3.9 GiB swap |
| 管理网络 | `wlan0`, `192.168.218.200/24` |
| LiDAR 网口 | `enP3p49s0`, `192.168.1.50/24` |
| MID-70 | `192.168.1.119`, broadcast code `3GGDLA4001V3191` |
| D435i | USB ID `8086:0b3a`, serial `135122072992` |
| D435i 固件 | `5.16.0.1` |
| SSD | `/mnt/ssd` |
| 配置目录 | `/mnt/ssd/daib-config` |
| rosbag 目录 | `/mnt/ssd/bags` |

本次使用的镜像：

```text
算法/Foxglove:
192.168.218.119:5050/daib-algorithm:openeuler-arm64

D435i:
192.168.218.119:5050/daib-drivers:openeuler-v4l2-20260811-arm64

MID-70:
192.168.218.119:5050/daib-drivers:mid70-fix-20260810-openeuler-arm64
```

这些带日期的驱动镜像已经过实机验证。不要用新构建覆盖现有标签；新版本应使用新标签，
保留可回退镜像。

## 3. 最终建议的运行边界

为了能够单独重启算法、修改参数、录包或切换其他算法，推荐使用以下边界：

```text
D435i ----> daib-camera-openeuler-v4l2 ---\
                                               \
MID-70 ---> daib-sensor-livox -----------------> daib-sensor-master (roscore)
                                                |          |
                                                |          +--> daib-foxglove
                                                |
                                                +------------> daib-algorithm
                                                               手动 roslaunch
```

容器职责：

| 容器 | 职责 | 建议重启策略 |
|---|---|---|
| `daib-sensor-master` | 只运行 `roscore` | `unless-stopped` |
| `daib-camera-openeuler-v4l2` | D435i RGB 和 IMU | `unless-stopped` |
| `daib-sensor-livox` | MID-70 | `unless-stopped` |
| `daib-foxglove` | Foxglove Bridge | `unless-stopped` |
| `daib-algorithm` | 空闲算法工作容器 | `unless-stopped`，但不自动启动算法 |

算法工作容器的 PID 1 只运行 `sleep infinity`。FAST-LIVO 或其他算法通过
`docker exec -it` 在前台启动，按 `Ctrl+C` 只停止该算法，不影响 Master、驱动和
Foxglove。

这是调试和算法切换拓扑。仓库现有 Compose 和入口脚本仍以“算法容器同时启动
roscore、FAST-LIVO 和 Foxglove”的耦合模式为主，不能直接等同于本拓扑。

截至文档写入时的状态边界：

| 项目 | 状态 |
|---|---|
| D435i 内核模块、RGB、融合 IMU | 已验证，含重启验证 |
| MID-70 持久网络和点云 | 已验证，含重启验证 |
| FAST-LIVO 三路输入和核心输出 | 已验证 |
| 独立 `daib-sensor-master` | 已验证，Master API 可用 |
| 独立 Foxglove 的短命令重建 | 已给出修复，尚未收到最终板端输出 |
| 空闲 `daib-algorithm` 工作容器 | 已给出迁移命令，尚未收到最终板端输出 |

## 4. D435i 内核模块

### 4.1 根因

板端原始 Rockchip 内核没有可用的 HID Sensor Hub 支持，D435i 的 RGB/UVC 可以枚举，
但 IMU 需要的 IIO accel/gyro 设备不会出现。仅安装 librealsense 用户态库无法弥补
缺失的内核驱动。

### 4.2 已安装模块

为精确匹配 `6.1.43-rockchip-rk3588` 构建并安装了以下外部模块：

```text
hid_sensor_hub
hid_sensor_iio_common
hid_sensor_trigger
hid_sensor_accel_3d
hid_sensor_gyro_3d
hid_sensor_custom
```

模块位置：

```text
/lib/modules/6.1.43-rockchip-rk3588/extra/d435i/
```

安装后需要执行 `depmod -a`，并通过 `/etc/modules-load.d/d435i.conf` 设置开机加载。
每次升级内核都必须为新的 `uname -r` 重新构建和安装，旧内核的 `.ko` 不能直接复用。

验证：

```bash
lsmod | grep -E 'hid_sensor_(hub|accel|gyro|trigger|iio|custom)'

for d in /sys/bus/iio/devices/iio:device*; do
  echo "===== $d ====="
  cat "$d/name" 2>/dev/null
  readlink -f "$d"
done
```

已验证结果包括：

```text
iio:device1  accel_3d
iio:device2  gyro_3d
```

IIO 编号不是稳定接口；板上 SAR ADC 占用了 `iio:device0`，重插 USB 后 accel/gyro
编号也可能变化。应用必须根据 `name` 和 sysfs 设备关系发现设备，不能硬编码编号。

## 5. D435i 容器

### 5.1 必要条件

D435i 容器最终使用：

- `--privileged`
- `--network host`
- `/dev:/dev`
- `/sys:/sys:rw`
- `/run/udev:/run/udev:ro`

关键经验是 `/sys` 必须为可写。最初只读挂载时，librealsense 能发现 RGB 和 IMU，
但无法开启 IIO scan element，日志包含：

```text
Failed to open scan_element .../in_accel_y_en
Last Error: Read-only file system
Hid device is busy!
```

这时 `Start publisher IMU` 并不代表 IMU 已经正常发布。最终必须用消息记录结果验证，
不能只看“设备已找到”日志。

### 5.2 已验证创建参数

```bash
RS_ARGS='enable_depth:=false enable_color:=true enable_gyro:=true enable_accel:=true'
RS_ARGS+=' unite_imu_method:=linear_interpolation color_width:=1280 color_height:=720 color_fps:=30'

docker run -d \
  --name daib-camera-openeuler-v4l2 \
  --restart unless-stopped \
  --privileged \
  --network host \
  -v /dev:/dev \
  -v /sys:/sys:rw \
  -v /run/udev:/run/udev:ro \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 \
  -e ROS_HOSTNAME=127.0.0.1 \
  -e ENABLE_REALSENSE=true \
  -e ENABLE_LIVOX=false \
  -e REALSENSE_ARGS="$RS_ARGS" \
  192.168.218.119:5050/daib-drivers:openeuler-v4l2-20260811-arm64
```

必须启用 `unite_imu_method:=linear_interpolation`，否则只有分离的 gyro/accel 话题，
不会产生 FAST-LIVO 使用的 `/camera/imu`。

验证 `/sys`：

```bash
docker exec daib-camera-openeuler-v4l2 \
  awk '$2=="/sys" {print}' /proc/mounts
```

预期包含 `sysfs rw`。

### 5.3 已验证数据

RGB + IMU 的短包结果：

```text
/camera/color/image_raw  10 msgs  sensor_msgs/Image
/camera/imu              10 msgs  sensor_msgs/Imu
duration                 0.3 s
size                     26.4 MB
```

原始 RGB 为 `1280x720 RGB8 @ 30 Hz`，理论裸数据约 82.9 MB/s。长时间录包和
Foxglove 订阅原始图像时都要考虑 CPU、内存复制、网络和磁盘带宽。

## 6. MID-70 网络

### 6.1 典型失败

容器入口最初可以临时设置：

```text
enP3p49s0 192.168.1.50/24 -> 192.168.1.119
```

MID-70 也能短暂连接并显示 `Lidar start sample success`。大约 15 秒后设备断开，随后
每秒出现：

```text
LocalIp and DeviceIp are not in same subnet
```

此时路由错误地变为：

```text
192.168.1.119 via 192.168.218.186 dev wlan0 src 192.168.218.200
```

根因不是 Livox SDK，也不是 `rp_filter`，而是 NetworkManager 的默认
`Wired connection 1` 一直处于 DHCP 获取地址状态，随后撤销了容器临时设置的静态
IPv4 地址。

### 6.2 持久 NetworkManager 配置

```bash
sudo nmcli connection add \
  type ethernet \
  ifname enP3p49s0 \
  con-name livox-mid70 \
  ipv4.method manual \
  ipv4.addresses 192.168.1.50/24 \
  ipv4.never-default yes \
  ipv6.method disabled \
  connection.autoconnect yes

sudo nmcli connection up livox-mid70

sudo nmcli connection modify \
  "Wired connection 1" \
  connection.autoconnect no

sudo nmcli connection modify \
  livox-mid70 \
  connection.autoconnect yes \
  connection.autoconnect-priority 100
```

验证：

```bash
ip -br addr show enP3p49s0
ip -4 route get 192.168.1.119
cat /proc/sys/net/ipv4/conf/all/rp_filter
cat /proc/sys/net/ipv4/conf/enP3p49s0/rp_filter
```

正确结果：

```text
enP3p49s0 UP 192.168.1.50/24
192.168.1.119 dev enP3p49s0 src 192.168.1.50
rp_filter = 0
```

不要为该连接设置默认网关；Wi-Fi 继续承担管理网络和默认路由。

### 6.3 已验证数据

网络修复后：

```text
/livox/lidar  10 msgs  livox_ros_driver/CustomMsg
duration      0.9 s
size          1.8 MB
```

重启验收确认 `192.168.1.50/24` 和直连路由可以自动恢复。

## 7. ROS Master 解耦

旧容器 `daib-sensor-master` 同时运行 roscore、FAST-LIVO 和 Foxglove。重启算法会导致
Master 一起消失，驱动和工具全部受影响，因此不适合频繁调参或切换算法。

迁移时没有立即删除旧容器，而是保留为可恢复备份：

```bash
docker stop daib-sensor-master
docker rename daib-sensor-master daib-sensor-master-coupled-backup
docker update --restart no daib-sensor-master-coupled-backup
```

独立 Master：

```bash
docker run -d \
  --name daib-sensor-master \
  --restart unless-stopped \
  --network host \
  --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 \
  -e ROS_HOSTNAME=127.0.0.1 \
  192.168.218.119:5050/daib-algorithm:openeuler-arm64 \
  -lc 'source /opt/ros/noetic/setup.bash; exec roscore'
```

`docker logs` 可能为空。不能据此判断 roscore 失败；本次通过以下三项确认其正常：

- 容器为 `Up`。
- PID 中存在 `roscore`、`rosmaster -p 11311` 和 `rosout`。
- `rosparam list` 返回 0。

```bash
docker top daib-sensor-master -eo pid,ppid,stat,cmd

docker exec daib-sensor-master bash -lc '
  source /opt/ros/noetic/setup.bash
  rosparam list >/dev/null
  echo "ros_master_rc=$?"
'
```

ROS1 驱动节点不应被假定为在 Master 重建后自动重新注册。更换 Master 后主动重启两个
驱动：

```bash
docker restart daib-sensor-livox daib-camera-openeuler-v4l2
```

旧耦合拓扑曾完成一次整机 reboot 验收：静态 LiDAR 地址和直连路由恢复，三个核心容器
自动启动，FAST-LIVO 再次产生 odometry、registered cloud 和 RGB 输出。这个结果证明
硬件和驱动具备重启恢复能力，但不能替代新五容器拓扑的最终断电验收。

## 8. Foxglove 解耦

算法镜像已经包含 Foxglove workspace。入口脚本在收到显式命令参数时会先 source
ROS、算法和 Foxglove workspace，等待 Master，然后直接 `exec` 该命令。因此独立
Foxglove 不需要重新写一条很长的 `source` 命令：

```bash
docker run -d \
  --name daib-foxglove \
  --restart unless-stopped \
  --network host \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 \
  -e ROS_HOSTNAME=127.0.0.1 \
  -e START_ROS_MASTER=false \
  192.168.218.119:5050/daib-algorithm:openeuler-arm64 \
  roslaunch --screen foxglove_bridge \
  foxglove_bridge.launch port:=8765
```

连接地址：

```text
ws://192.168.218.200:8765/
```

第一次创建 Foxglove 容器时，复制粘贴把
`/opt/foxglove_ws/devel/setup.bash` 从路径中间断成两行。容器不断重启并输出：

```text
source: /opt/foxglove_ws/devel/: is a directory
setup.bash: command not found
foxglove_bridge.launch is neither a launch file ...
```

修复方法是删除这个没有持久数据的错误容器，并使用上面的短命令重建。排障时应检查
实际保存的参数，而不是只看终端中视觉换行：

```bash
docker inspect daib-foxglove --format '{{json .Args}}'
```

Foxglove 没有客户端订阅时开销较低。订阅未压缩的 1280x720@30 Hz 原始 RGB 或多个
大点云时，桥接序列化和网络流量才是主要开销。日常优先使用 10 Hz 图像和必要点云。

RealSense 驱动运行在独立 drivers 容器，而 Foxglove bridge 运行在 algorithm 容器。
ROS1 网络会传递消息，但不会跨容器传递 `.msg` 定义。旧 algorithm 镜像因此会对以下
辅助话题报告空 schema：

```text
/camera/color/metadata       realsense2_camera/Metadata
/camera/gyro/imu_info        realsense2_camera/IMUInfo
/camera/accel/imu_info       realsense2_camera/IMUInfo
```

包含 RealSense 2.3.2 原始消息定义的修复镜像为：

```text
192.168.218.119:5050/daib-algorithm:sync-yyy-realsense-schema-20260813-arm64
sha256:97e3291aace4770d6fcc9e683ec5bf539e15429e6ddfdc26ee9840d6ddf6d8a0
```

该修复只向 Foxglove workspace 添加 `Metadata.msg` 和 `IMUInfo.msg`，不在 algorithm
容器中安装或启动完整 RealSense 驱动。两个消息类型的 ROS MD5 已与 drivers 镜像中的
realsense-ros 2.3.2 核对一致。旧镜像中这些 schema 报错不影响 FAST-LIVO 主输入
`/camera/imu`，但使用新镜像后 Foxglove 可以正常解析三个辅助话题。

## 9. 自由使用算法工作容器

### 9.1 设计原则

不要让 PID 1 自动启动 FAST-LIVO。容器保持空闲，算法在交互 shell 中手动启动。
这样可以：

- 按 `Ctrl+C` 停止当前算法。
- 修改配置后重新 `roslaunch`。
- 启动 Planner、Explorer 或镜像内的其他 ROS 算法。
- 必要时 `docker restart daib-algorithm` 一次清理容器内全部算法进程。
- 保持 Master、驱动和 Foxglove 不动。

不要用 `docker pause` 作为正常停止方式。它会冻结进程、连接和缓存；调试时应使用
`Ctrl+C`，异常时重启算法工作容器。

### 9.2 创建工作容器

先保留自动启动版容器：

```bash
docker stop daib-fast-livo
docker rename daib-fast-livo daib-fast-livo-auto-backup
docker update --restart no daib-fast-livo-auto-backup
```

创建通用工作容器：

```bash
docker run -d \
  --name daib-algorithm \
  --restart unless-stopped \
  --network host \
  --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 \
  -e ROS_HOSTNAME=127.0.0.1 \
  -v /mnt/ssd/daib-config/mid70_d435i.yaml:/opt/daib_ws/src/fast_livo/config/mid70_d435i.yaml \
  -v /mnt/ssd/bags:/bags \
  192.168.218.119:5050/daib-algorithm:openeuler-arm64 \
  -lc 'exec sleep infinity'
```

截至本文写入时，这个最终工作容器迁移命令已经给出，但尚未收到板端创建后的完整输出，
因此需要按第 15 节重新验收。

### 9.3 进入环境并启动 FAST-LIVO

```bash
docker exec -it daib-algorithm bash -lc '
  source /opt/ros/noetic/setup.bash
  source /opt/daib_ws/devel/setup.bash
  source /opt/foxglove_ws/devel/setup.bash --extend
  exec bash -i
'
```

容器内：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch \
  rviz:=false \
  use_camera:=true
```

FAST-LIVO 启动后保持整套传感器静止约 5 秒，使约 1000 帧 D435i IMU 完成初始化。

如果 SSH 会话可能断开，使用板端已有的 `tmux` 保持交互会话。不要用不受管理的
`nohup ... &` 启动多个同名算法节点，否则容易留下重复 publisher。

### 9.4 手动启动 Explorer 和 EGO Planner

FAST-LIVO 稳定发布 `/daib_slam/odom` 与 `/daib_slam/planning_cloud` 后，在独立终端
启动 Planner：

```bash
docker exec -it daib-algorithm bash -lc '
  source /opt/ros/noetic/setup.bash
  source /opt/daib_ws/devel/setup.bash
  exec roslaunch ego_planner daib_single_uav.launch
'
```

必须使用 `daib_single_uav.launch`，不要使用仿真入口 `simple_run.launch`。该入口同时
启动：

- `daib_ego_bridge`，将 `/daib_explorer/goal` 校验并转发到 `/daib_ego/goal`；
- EGO Planner，订阅 `/daib_slam/odom` 与 `/daib_explorer/planning_cloud`；
- `traj_server`，输出 `/daib_ego/position_cmd`。

当前 launch 不连接 PX4 或飞控。`/daib_ego/position_cmd` 只是控制器接口，单独启动
Planner 不会让无人机运动。

随后在另一个终端启动 Explorer。Planner 应先于 Explorer 启动，使它在 Explorer
发布首个 goal 前已经订阅 `/daib_explorer/planning_cloud`。如果 Explorer 已在运行且
存在锁存 goal，Planner 可能先收到 goal、后收到第一帧 planning cloud，并立即进入：

```text
Waiting for the first independent planning cloud.
Depth Lost! EMERGENCY_STOP
```

当前急停状态不会因后续 cloud 到达自动恢复。遇到该状态时停止 Planner，确认
planning cloud 正常，再按“Planner 先、Explorer 后”的顺序重启。

启动检查：

```bash
rostopic hz /daib_explorer/planning_cloud
rostopic echo /daib_ego/bridge_state
rostopic echo -n 1 /daib_ego/goal
rostopic info /daib_ego/position_cmd
```

Bridge 常见状态：

- `WAIT_EXPLORER`：Explorer 未 ready 或 ready 心跳过期；
- `WAIT_ODOM`：尚无新鲜 odometry；
- `GOAL_FORWARDED`：goal 已通过校验并送入 EGO。

### 9.5 EGO 障碍点云可视化

在 Foxglove 3D 面板中将 Fixed Frame 设为 `camera_init`，添加以下 PointCloud2：

```text
/daib_explorer/planning_cloud
/drone_0_ego_planner_node/grid_map/occupancy_inflate
```

两者含义不同：

- `/daib_explorer/planning_cloud` 是 Explorer 送给 EGO 的原始 occupied 体素中心；
- `/drone_0_ego_planner_node/grid_map/occupancy_inflate` 是按 EGO 分辨率和
  `grid_map/obstacles_inflation` 膨胀后、真正参与碰撞检测的地图。

可同时显示 `/daib_slam/odom` 对应的 `aft_mapped` TF 或 odometry pose，观察当前位置
是否落入膨胀点云。当前 independent-cloud 模式使用 `grid_map/pose_type=2`，只更新
`occupancy_buffer_inflate_`；因此：

```text
/drone_0_ego_planner_node/grid_map/occupancy
```

可能为空，不能用它判断 EGO 是否收到了障碍。

以下日志表示轨迹起点本身已被膨胀地图占用：

```text
Current odometry position is inside the inflated planning map
Initial trajectory is occupied: t=0.000
Unable to find a free control point before collision
```

例如最近原始障碍为 `0.449 m`、膨胀半径为 `0.500 m` 时，EGO 会正确地拒绝从当前
位置生成轨迹。此时先在 Foxglove 中判断近点是真实墙面、地面、自身机架还是传感器
伪点，不要仅为消除日志直接降低障碍膨胀半径。

### 9.6 开环 Planner 测试的预期日志

仅观察 Planner、没有控制器执行 `/daib_ego/position_cmd` 时，真实 odometry 不会跟随
EGO 生成的轨迹。随后可能持续出现：

```text
Tracking error exceeded replan threshold; anchor new trajectory to odometry
```

默认位置/速度阈值为 `0.5 m` 和 `0.8 m/s`。如果每次仍有 `plan_success=1`，说明规划
链路可以生成轨迹；该警告不能用于评价闭环跟踪性能。若出现 `plan_success=0` 且日志
同时报告起点占用，应先处理地图或机体附近点，而不是调优化器。

## 10. SSD 配置与权限

创建配置和 bag 目录时曾遇到 `/mnt/ssd` 本身属于 UID/GID 984。`docker cp` 先打印：

```text
Successfully copied 512B
```

随后又报：

```text
open /mnt/ssd/daib-config/mid70_d435i.yaml: permission denied
```

“Successfully copied”只表示容器端数据流已读取，不代表宿主机目标文件已成功创建。

正确处理：

```bash
sudo install -d -o orangepi -g orangepi -m 0755 \
  /mnt/ssd/daib-config \
  /mnt/ssd/bags
```

算法镜像中的包目录是 `/opt/daib_ws/src/fast_livo`，不是
`/opt/daib_ws/src/DAIB-LIVO`。正确复制命令：

```bash
docker cp \
  daib-sensor-master:/opt/daib_ws/src/fast_livo/config/mid70_d435i.yaml \
  /mnt/ssd/daib-config/mid70_d435i.yaml
```

已复制配置大小约 2.8 KiB，属主为 `orangepi:orangepi`。

## 11. VIO 力度

> **2026-08-12 基线更正**：当前 `sync_yyy` 主线
> `mapping_mid70_d435i.launch` 已支持 `vio_img_point_cov`，默认值为 `100`。当前唯一
> 依据见 [`CURRENT_SYNC_YYY_BASELINE.md`](CURRENT_SYNC_YYY_BASELINE.md)。该接口需要
> 使用包含 `DAIB-LIVO@58b3af5` 的新镜像；旧板端镜像不保证支持。

当前配置项：

```yaml
vio:
  img_point_cov: 100
```

实现从 ROS 参数 `/vio/img_point_cov` 读取该值。数值越大，图像观测协方差越大，
视觉对共享位姿的修正越弱，但不是线性的“百分比旋钮”。建议阶梯：

| 值 | 用途 |
|---:|---|
| 100 | 当前基线，视觉较强 |
| 300 | 轻度弱化 |
| 500 | 中度弱化 |
| 1000 | 明显弱化，外参仍在验证时的建议起点 |
| 2000 | 很弱，仅保留较小视觉修正 |

当前主线可直接在启动时覆盖：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch \
  rviz:=false \
  use_camera:=true \
  vio_img_point_cov:=1000
```

不需要弱化视觉时可省略该参数，等价于默认值 `100`：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch \
  rviz:=false \
  use_camera:=true
```

启动后用 `rosparam get /vio/img_point_cov` 验证实际加载值。该参数只在节点初始化时
读取；改变力度必须停止并重新启动 `laserMapping`，运行中执行 `rosparam set` 不会刷新
VIOManager 已保存的值。

`vio_state_update` 和 `vio_diagnostics` 仍不是该 launch 的有效参数，不要传入。

## 12. 时间戳：驱动修正

MID-70 在没有有效 PTP/PPS/GPS 同步源时，可能输出设备开机时间而不是 Unix epoch。
这会导致它无法与 D435i 的系统 epoch 时间直接融合。

`patches/livox_ros_driver-nosync-system-time.patch` 在完整 `CustomMsg` 组帧后执行：

1. 读取最后一个点的 `offset_time` 作为扫描持续时间。
2. 读取 `ros::Time::now()` 作为发布时间。
3. 如果原始 `timebase` 与发布时间相差超过 1 秒，判定为非 epoch 时基。
4. 将扫描起点改为“发布时间减扫描持续时间”。
5. 同时更新 `livox_msg.timebase` 和 `header.stamp`。
6. 保留每个点原始 `offset_time`。

日志只打印一次：

```text
Non-epoch CustomMsg timestamp mapping v4 enabled
```

如果原始时间已经在系统 epoch 的 1 秒以内，补丁不修改它。

这一修正解决的是“时基完全不同”的软件兼容问题。它使用主机发布时间反推扫描起点，
会包含驱动调度和接收延迟，不等价于 PTP/PPS 硬件同步。

## 13. 时间戳检查器实际逻辑

历史源码位于 DAIB-LIVO 子模块提交 `a8f489a` 的
`scripts/check_sensor_timing.py`。`scripts/start_mid70_d435i_drivers.sh` 会使用
`--validate` 调用它。

### 13.1 采集的时间

对 LiDAR、IMU 和 Image 都记录：

```text
msg.header.stamp.to_sec()   ROS 消息头时间
time.time()                 Python 回调执行时的系统墙钟时间
```

LiDAR 还记录：

```text
msg.point_num
max(point.offset_time)      扫描持续时间
```

采集前预热 1 秒，用于绕开 D435i 新订阅者可能收到的第一条缓存 IMU。

### 13.2 校验阈值

| 检查 | 通过范围 |
|---|---:|
| LiDAR header 频率 | 8-12 Hz |
| IMU header 频率 | 150-260 Hz |
| Image header 频率 | 25-35 Hz |
| 三路 header 回退 | 必须为 0；相邻间隔 `<= 0` 算回退 |
| IMU 到达墙钟减 header 中位数 | -20 至 80 ms |
| Image 到达墙钟减 header 中位数 | -20 至 120 ms |
| LiDAR 中位点数 | 至少 9000 |
| LiDAR 中位扫描时长 | 80-120 ms |
| LiDAR 扫描结束到回调到达中位数 | -20 至 80 ms |
| 每帧 LiDAR 起点到最近 IMU 的绝对差 P95 | 不超过 10 ms |
| 每帧 LiDAR 起点到最近 Image 的绝对差 P95 | 不超过 25 ms |

LiDAR 的 `header.stamp` 表示扫描起点。消息约在 100 ms 扫描结束后发布，所以不能直接
要求 `arrival - header` 接近 0；脚本比较的是：

```text
arrival - lidar_header_stamp - scan_duration
```

### 13.3 它能证明什么

通过该检查可以说明：

- 三路消息持续到达，header 时间在检查窗口内单调前进。
- header 频率符合当前设备配置。
- header 与主机墙钟处于同一数量级的 epoch 时基，没有明显陈旧或未来时间。
- LiDAR 扫描持续时间和点数合理。
- 三路 header 在软件时间轴上的最近邻差没有超过当前阈值。

### 13.4 它不能证明什么

通过该检查不能证明：

- D435i 与 MID-70 已经实现硬件同步。
- 图像曝光中点、IMU 采样时刻和 LiDAR 点时间语义完全一致。
- 相机与 LiDAR 外参正确。
- 长时间运行没有时钟漂移。
- 最近邻消息就是同一个物理事件。
- 所有消息都不陈旧；到达延迟只校验中位数，少量严重异常可以被掩盖。
- 主机自己的系统时间已经通过 NTP/PTP 与外部标准时间同步。

对于 200 Hz IMU 和 30 Hz 图像，只要三路处于同一大致时基，最近邻差自然可能很小。
因此最近邻 P95 是软件一致性检查，不是硬件同步证据。真正的硬件同步需要触发线、
PPS/PTP、设备时钟状态和运动事件相关性等独立证据。

### 13.5 当前 Python 3.11 风险

当前 openEuler 算法容器使用 Python 3.11.6。实测发现：

- 只 source `/opt/daib_ws/devel/setup.bash` 时，检查器无法导入
  `livox_ros_driver.msg`。
- Foxglove workspace 确实包含生成的 `_CustomMsg.py`，但 workspace source 顺序会
  改写 `PYTHONPATH`。
- 在能够导入消息后，`rospy.init_node` 的错误日志路径出现递归，最终触发
  `RecursionError`，产生大量 traceback。

仓库工作树当前还只见
`check_sensor_timing.cpython-314.pyc`，源码可从子模块提交 `a8f489a` 读取。
Python 3.14 的 `.pyc` 不能替代 Python 3.11 容器中的源码；重新构建前必须确认 `.py`
被正确包含。

结论：在修复 Python ROS 环境或改写为 C++ 检查器前，不应把当前 Python 检查器作为
板端唯一启动门禁。

## 14. rosbag 验收与已知脚本问题

### 14.1 不使用 `rostopic echo`

板端 Python 3.11 ROS 工具链在 `rostopic echo` 和部分 rospy 错误路径中出现过
递归异常。当前约定是：

```text
不要使用 rostopic echo 验收高频传感器数据。
```

优先使用 C++ `rosbag record`，然后检查消息数量、持续时间、类型和文件大小。

注意：`rosbag info` 只能证明消息已记录及大致频率，不能单独证明 header 时间正确。
完整时间验收仍需要可靠的 C++ 时间检查器或离线读取 bag 的 header。

### 14.2 当前录包脚本不能原样使用

`scripts/record_fast_livo_inputs.sh` 当前仍有多处：

```text
rostopic echo -n 1 .../header/stamp
rostopic echo -n 2 .../header
```

同时它按 Compose 的 `algorithm` service 查找容器和 `/bags` mount，与新的手动工作容器
拓扑不一致。在替换这些检查并适配独立 Master 前，不要原样运行该脚本。

### 14.3 独立短包验证

录包应使用独立临时容器，避免停止算法时中断 recorder。示例：

```bash
BAG_NAME="fast-livo-inputs-$(date +%Y%m%d_%H%M%S)"

docker run --rm -it \
  --name daib-recorder \
  --network host \
  --entrypoint /bin/bash \
  -e ROS_MASTER_URI=http://127.0.0.1:11311 \
  -e ROS_HOSTNAME=127.0.0.1 \
  -e BAG_NAME="$BAG_NAME" \
  -v /mnt/ssd/bags:/bags \
  192.168.218.119:5050/daib-algorithm:openeuler-arm64 \
  -lc 'source /opt/ros/noetic/setup.bash; exec rosbag record --lz4 --split --size=4096 --buffsize=512 -O "/bags/${BAG_NAME}" /livox/lidar /camera/imu /camera/color/image_raw'
```

按 `Ctrl+C` 后等待 rosbag 完成索引写入。不要直接 `docker kill` recorder；必须优先发送
SIGINT 并等待 `.bag.active` 消失。

如果算法正在运行且只需要 FAST-LIVO 实际消费的 10 Hz 图像，可以将
`/camera/color/image_raw` 改为 `/camera/color/image_fast_livo`。

## 15. 已完成的端到端验收

### 15.1 输入

同时录制三路输入：

```text
/livox/lidar             10 msgs  livox_ros_driver/CustomMsg
/camera/color/image_raw  10 msgs  sensor_msgs/Image
/camera/imu              10 msgs  sensor_msgs/Imu
duration                 1.0 s
size                     28.2 MB
```

### 15.2 FAST-LIVO 日志

算法日志持续交替出现：

```text
Get LiDAR, its header time: ...
Get image, its header time: ...
```

日志样本中时间持续递增，没有看到 `not synced`、`loop back`、`out sync` 或相关 ERROR。
这说明算法在持续消费 LiDAR 和图像，但不能替代完整时间同步证明。

### 15.3 输出

```text
/aft_mapped_to_init  10 msgs  nav_msgs/Odometry
/cloud_registered    10 msgs  sensor_msgs/PointCloud2
/path                10 msgs  nav_msgs/Path
/rgb_img             10 msgs  sensor_msgs/Image
duration             1.2 s
size                 27.0 MB
```

重启后再次录制：

```text
/aft_mapped_to_init  5 msgs
/cloud_registered    5 msgs
/rgb_img             5 msgs
```

`/rgb_img` 有持续输出，说明视觉处理路径实际运行，不只是相机原始话题存在。
`/daib_slam/odom` 在本次验收中没有出现，不应列为当前 FAST-LIVO 核心输出。

## 16. 新拓扑验收顺序

每次重启或改变容器边界后按以下顺序验证：

1. 检查 `enP3p49s0` 地址和到 `192.168.1.119` 的直连路由。
2. 检查 D435i IIO accel/gyro 和内核模块。
3. 启动并验证独立 `daib-sensor-master`。
4. 重启 D435i 和 MID-70 驱动，使其向新 Master 注册。
5. 启动独立 Foxglove，确认 TCP 8765。
6. 进入 `daib-algorithm`，手动启动 FAST-LIVO。
7. 用短 rosbag 验证三路输入。
8. 保持设备静止完成 IMU 初始化。
9. 用短 rosbag 验证 FAST-LIVO 核心输出。
10. 最后再进行运动、回环、VIO 权重和外参效果测试。

基础检查：

```bash
ip -br addr show enP3p49s0
ip -4 route get 192.168.1.119

docker ps -a --format \
  'table {{.Names}}\t{{.Status}}\t{{.Image}}'

ss -lnt | grep -E ':(11311|8765)\b'
```

## 17. 性能实测

拆分容器后的一次快照：

| 容器 | CPU | 内存 |
|---|---:|---:|
| `daib-fast-livo` | 139.39% | 650.9 MiB |
| D435i | 57.86% | 95.64 MiB |
| MID-70 | 6.61% | 59.45 MiB |
| ROS Master | 1.64% | 100.3 MiB |

Docker 的 100% CPU 约表示一个逻辑核。此快照约使用 2.05 个逻辑核；系统总内存使用
约 1.2 GiB，可用约 6.5 GiB。

Foxglove 当时处于错误重启循环，`0B` 不能作为正常负载数据，因此未列入表中。

容器共享宿主机内核和镜像层，容器数量本身不是主要性能瓶颈。主要成本是：

- FAST-LIVO 计算。
- 1280x720 RGB 图像处理和复制。
- ROS 消息序列化。
- Foxglove 客户端实际订阅的图像和点云流量。

将 ROS 节点拆到多个 host-network 容器不会引入虚拟机开销，也不经过 Docker bridge
NAT。其运行开销远小于图像和算法本身，换来的独立启停和故障隔离更有价值。

## 18. 回退

迁移过程中保留了耦合容器和自动 FAST-LIVO 容器，不要在新方案验收前删除：

```text
daib-sensor-master-coupled-backup
daib-fast-livo-auto-backup
```

如需恢复旧的 Master + FAST-LIVO + Foxglove 耦合容器，必须先停止占用 host-network
11311/8765 的新容器：

```bash
docker stop daib-algorithm daib-foxglove daib-sensor-master
docker start daib-sensor-master-coupled-backup
docker restart daib-sensor-livox daib-camera-openeuler-v4l2
```

不要同时运行新旧 Master，也不要同时运行两个 FAST-LIVO 实例发布同名话题。

## 19. 后续必须修复

1. 将 `check_sensor_timing.py` 恢复为受版本控制的源码，并解决 openEuler Python 3.11
   的 rospy 递归异常；更稳妥的方案是提供 C++ 时间检查器。
2. 修改 `scripts/start_mid70_d435i_drivers.sh`，正确叠加 Livox 消息 workspace，且不要
   依赖当前不稳定的 Python 检查器。
3. 修改 `scripts/record_fast_livo_inputs.sh`，移除所有 `rostopic echo`，并适配独立
   Master、独立 recorder 和通用算法工作容器。
4. 给 `mapping_mid70_d435i.launch` 增加显式配置文件参数，使多个 YAML 可并存选择，
   而不是反复覆盖唯一的 `mid70_d435i.yaml`。
5. 如需运行时调 VIO 权重，实现 dynamic_reconfigure 或节点内参数刷新；当前参数只在
   启动时读取。
6. 在新五容器拓扑下完成一次断电重启验收，确认 SSD 先于 Docker 挂载，并重新验证
   输入、输出、Foxglove 和手动算法工作流。

## 20. 最重要的经验

- “设备被发现”不等于“消息正在发布”；用 rosbag 数据验收。
- D435i IMU 不只需要用户态库，还需要正确的 HID/IIO 内核模块。
- `/sys` 只读会让 librealsense IMU 在最后开启 scan element 时失败。
- Livox 短暂连接后断开时，先检查 NetworkManager 和实际路由，不要只看 SDK 日志。
- `ip addr` 临时配置不能对抗 NetworkManager，必须建立持久 profile。
- `restart=unless-stopped` 不能解决 ROS Master 与算法生命周期耦合。
- 算法、Master、驱动、Foxglove 和 recorder 应有独立生命周期。
- `docker logs` 为空不代表进程没运行；结合状态、PID、端口和协议检查。
- 终端视觉换行也可能变成命令参数中的真实换行；用 `docker inspect .Args` 确认。
- `docker cp` 的“Successfully copied”可能出现在宿主机最终落盘失败之前。
- ROS header 接近只证明软件时基一致，不证明硬件同步和标定正确。
- 高频 ROS Python CLI 在当前 Python 3.11 环境不可靠，优先使用 C++ 工具和 rosbag。
- 配置参数是否可从 launch 覆盖必须读 launch 文件确认，不能依赖旧文档或参数名猜测。
- 调试算法使用前台 `roslaunch` + `Ctrl+C`；不要用 `docker pause` 或留下无管理后台进程。

## 21. 日常排障原则

### 21.1 容器名过滤是子串匹配

以下命令会同时匹配 `daib-sensor-master` 和
`daib-sensor-master-coupled-backup`：

```bash
docker ps -a --filter name=daib-sensor-master
```

需要唯一容器时使用精确正则：

```bash
docker ps -a --filter 'name=^/daib-sensor-master$'
```

### 21.2 短时间日志为空不代表失败

`docker logs --since 20s ... | grep ...` 只检查时间窗口内且匹配正则的行。驱动启动信息
可能已经早于该窗口，或者正常运行期间没有重复日志。应同时检查：

```text
容器状态 -> 进程 -> 端口/ROS Master -> 实际消息记录
```

不要因为 grep 为空就重建已验证容器。

### 21.3 退出码 137 不能直接写成 OOM

`Exited (137)` 表示进程收到 SIGKILL，可能来自 OOM、`docker kill`、主机重启或其他
外部终止。先检查：

```bash
docker inspect CONTAINER --format \
  'exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}'
```

没有 `OOMKilled=true` 或内核日志证据时，不要把 137 直接归因为内存不足。

### 21.4 多行粘贴必须检查实际参数

终端窄屏显示造成的视觉换行通常无害，但粘贴文本中的真实换行会改变参数。长路径、
环境变量和 shell 命令出错时检查：

```bash
docker inspect CONTAINER --format \
  'entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}} args={{json .Args}}'
```

优先利用镜像已有 entrypoint，并把命令参数直接传给它，减少嵌套 shell 和长引号。
