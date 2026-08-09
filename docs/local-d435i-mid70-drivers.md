# 本机 D435i + Livox MID-70 驱动

更新日期：2026-08-07

> 本文记录的是 `192.168.126.131` 上旧的 x86 Ubuntu 双容器环境，仅保留作历史
> 排障参考。当前仓库中的同名启动与录包脚本已经适配 Orange Pi 5 Max 的
> `algorithm`/`drivers` Compose 架构；实机操作以
> [`deploy/README.md`](../deploy/README.md) 为准，不要在旧环境中混用。

## 1. 当前拓扑

实体传感器先在本机运行，不使用 Atlas 开发板容器：

```text
D435i --USB--> ros1-realsense --\
                                ROS Master 127.0.0.1:11311 --> ros1-rviz / FAST-LIVO2
MID-70 --Ethernet-------------> ros1-rviz ------------------/
```

- `ros1-rviz`：Ubuntu 20.04、ROS Noetic、FAST-LIVO2 和
  `livox_ros_driver`。
- `ros1-realsense`：与主容器使用 host 网络，只运行 D435i 驱动；容器为
  privileged，因此 D435i 必须先连接，再启动或重启该容器，使 V4L2、IIO 和
  hidraw 设备节点进入容器。
- 两个容器必须使用同一个本机 ROS Master，不能沿用指向开发板
  `192.168.0.2` 的旧环境变量。

## 2. 已安装版本

```text
livox_ros_driver:               upstream commit 3d240d5
realsense2_camera ROS wrapper:  2.3.2
librealsense runtime:           2.55.1, native V4L2 backend
D435i firmware:                 5.16.0.1
```

当前 Livox 源码和内置 Livox SDK 都包含 MID-70 设备类型支持。

ROS wrapper 是 Noetic 官方最后一版，编译信息会显示 librealsense 2.50.0；运行时
动态链接本机源码安装的 2.55.1 V4L2 库，因此启动时会出现版本不同警告。当前组合
已经过 RGB、深度和 IMU 实测。不要改回 RSUSB 后端：本机上它会触发 RGB8/YUYV
转换错误和 UVC 控制传输冲突。

`ros1-realsense` 的 apt 和 shell 已配置代理
`http://192.168.126.119:7897`，本次依赖安装通过该代理完成。

## 3. 启动容器和 ROS Master

推荐从宿主机使用一键启动与验收脚本。脚本不会启动 FAST-LIVO2：

```bash
cd /home/ufd/cc-chat
bash scripts/start_mid70_d435i_drivers.sh
```

默认连续检查 8 秒，也可以指定 3 到 60 秒：

```bash
bash scripts/start_mid70_d435i_drivers.sh --check-seconds 15
```

脚本会检查 D435i USB、网口、容器、ROS Master、核心话题、相机分辨率、消息类型、
LiDAR 点数、三个传感器频率、时间戳回退、扫描时长及传感器最近邻时间差。只有输出
`[PASS] D435i and MID-70 are ready` 才表示驱动通过验收。

驱动的 stdout/stderr 默认写入 `/dev/null`，ROS 运行日志放在容器的 `/dev/shm` 内存盘，
每次启动前会清空内存日志、历史 `/root/.ros/log` 和旧驱动日志，不会持续占用宿主机
或容器磁盘。Livox 只在需要重新编译时临时写一份构建日志，成功或输出错误后立即删除。

从 rosbag 回到实机时，脚本会自动将 `/use_sim_time` 恢复为 `false`，并清理已经
退出的播放节点和传感器节点注册，不需要手工恢复 ROS 时间。

MID-70 没有有效 PTP/PPS 输入时，可能会上报 NoSync `timestamp_type[0]`，也可能
残留为 PPS-only `timestamp_type[4]`；两种情况下原始时间戳都可能只是设备计时，
不能直接与 D435i 的系统 epoch 时间配对。首次运行脚本时会自动给容器内的
`livox_ros_driver` 应用时间基准补丁并重新编译。补丁在完整
`CustomMsg` 组帧后，以系统发布时间减去消息内扫描时长作为扫描起点，保留所有点的
`offset_time`。它只修正与系统时间相差超过 1 秒的非 epoch 时间戳，不改变有效的
PTP/PPS/GPS 时间戳；后续启动检测到已编译的补丁后不会重复构建。补丁文件为：

```text
/home/ufd/cc-chat/patches/livox_ros_driver-nosync-system-time.patch
```

以下为需要分终端手动启动时的等价步骤。

```bash
# 先接好 D435i，再启动；若运行中重新插拔过相机，重启侧车以刷新 /dev 节点。
docker start ros1-rviz ros1-realsense
docker restart ros1-realsense

docker exec -it ros1-rviz bash
source /opt/ros/noetic/setup.bash
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP
roscore
```

## 4. 启动 D435i

在宿主机的新终端执行：

```bash
docker exec -it ros1-realsense bash
source /opt/ros/noetic/setup.bash
source /root/realsense_ws/devel/setup.bash
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP

roslaunch realsense2_camera rs_camera.launch \
  enable_depth:=true \
  enable_color:=true \
  enable_gyro:=true \
  enable_accel:=true \
  unite_imu_method:=linear_interpolation
```

FAST-LIVO2 需要的主要话题为：

```text
/camera/color/image_raw
/camera/color/camera_info
/camera/imu
```

`unite_imu_method` 必须启用，否则驱动只发布分离的 gyro 和 accel，不能直接作为
FAST-LIVO2 的 `sensor_msgs/Imu` 输入。

## 5. 启动 MID-70

当前 MID-70 地址为 `192.168.1.119`，连接在 `enp3s0`。通过 privileged 且使用
host 网络的相机侧车配置主机地址，不添加网关，不影响 Wi-Fi 默认路由：

```bash
docker exec ros1-realsense \
  ip addr replace 192.168.1.50/24 dev enp3s0
docker exec ros1-realsense ip link set enp3s0 up
```

然后在主容器的新终端执行。默认参数 `100000000000000` 会被驱动判定为无效占位符，
从而进入自动发现模式，所以当前不需要手工填写 broadcast code：

```bash
docker exec -it ros1-rviz bash
source /opt/ros/noetic/setup.bash
source /root/catkin_ws/devel/setup.bash
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
unset ROS_IP

roslaunch livox_ros_driver livox_lidar_msg.launch publish_freq:=10.0
```

FAST-LIVO2 使用的话题和类型为：

```text
/livox/lidar  livox_ros_driver/CustomMsg
```

MID-70 不提供 FAST-LIVO2 所需的内置 IMU 数据，本机方案使用 D435i 合并后的
`/camera/imu`。

## 6. 接入 FAST-LIVO2 前必须修改的配置

现有 `/root/daib_fastlivo_ws/src/fast_livo/config/avia.yaml` 是 Gazebo 配置，话题、
相机内参和外参都不能直接用于实体传感器。实机配置至少需要改为：

```yaml
common:
  img_topic: "/camera/color/image_raw"
  lid_topic: "/livox/lidar"
  imu_topic: "/camera/imu"
```

相机内参应读取 D435i 的 `/camera/color/camera_info`；LiDAR 到 IMU、LiDAR 到相机
外参必须按实际安装位置标定。未完成标定前只能检查驱动话题，不能把 SLAM 结果
作为有效定位结果。

## 7. 驱动检查

```bash
rostopic type /livox/lidar
rostopic hz /livox/lidar
rostopic hz /camera/color/image_raw
rostopic hz /camera/imu
rostopic echo -n 1 /camera/color/camera_info
```

2026-08-06 实测结果：

```text
/camera/color/image_raw       29.97 Hz
/camera/depth/image_rect_raw  29.97 Hz
/camera/imu                  199.3 Hz
/livox/lidar                  10.00 Hz, CustomMsg, 约 9984 点/帧
enp3s0 RX errors/dropped       0/0
```

本次读取的 D435i 彩色相机矩阵为：

```text
K = [915.7250, 0, 638.8065,
     0, 913.8582, 365.1039,
     0, 0, 1]
```

外参未提供前不要直接启动实体 FAST-LIVO2。收到 LiDAR-IMU、LiDAR-camera 外参后，
应创建单独的实机 YAML，不能覆盖现有 Gazebo `avia.yaml`。

## 8. 时间对齐实测

2026-08-06 在两个驱动稳定运行后连续采样 30 秒：

```text
LiDAR  header.stamp     epoch 时基，10.000 Hz，无回退
IMU    header.stamp     epoch 时基，约 200 Hz，无回退
Image  header.stamp     epoch 时基，29.98 Hz，无回退
LiDAR 扫描持续时间      99.83 ms
LiDAR 最近邻 IMU        绝对时间差中位数 1.22 ms，P95 2.38 ms
LiDAR 最近邻 Image      绝对时间差中位数 11.34 ms，P95 16.09 ms
```

LiDAR 消息的 `header.stamp` 是扫描起点，点级 `offset_time` 从 0 递增到约
99.83 ms；消息在扫描结束后发布，所以接收时刻比 `header.stamp` 晚约 102 ms 是
正常现象，不代表额外的 102 ms 时间偏移。

2026-08-07 复测发现雷达驱动重启后可能直接发布设备开机时间。旧文档只记录了上面
一次 epoch 时基正常的结果，没有把它作为启动必检条件。当前脚本会在消息完整组帧
后根据系统发布时间重建非 epoch 扫描起点，并额外校验 LiDAR 扫描结束到消息到达的
延迟；如果时间基准不一致，脚本会失败并阻止继续启动 FAST-LIVO2。

D435i 的 `/camera/imu` 对每个新订阅者会先发送一条缓存的旧消息，随后一条消息立即
跳到当前时间，之后稳定约 200 Hz。FAST-LIVO2 在收到首帧 LiDAR 前会忽略 IMU，
但诊断程序仍需预热 1 秒以排除这条缓存消息。

可重复执行以下检查：

```bash
docker exec -it ros1-rviz bash
source /opt/ros/noetic/setup.bash
source /root/daib_fastlivo_ws/devel/setup.bash
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
rosrun fast_livo check_sensor_timing.py --duration 30
```

## 9. 实机 FAST-LIVO2 配置

独立配置文件为：

```text
/root/daib_fastlivo_ws/src/fast_livo/config/mid70_d435i.yaml
/root/daib_fastlivo_ws/src/fast_livo/launch/mapping_mid70_d435i.launch
```

该配置使用交付标定包中的 LiDAR 到 D435i IMU optical frame、LiDAR 到 Color
Optical frame 外参和 1280x720 彩色相机内参。默认只运行 LIO，以便先隔离视觉和
相机外参问题。启动后整套传感器必须静止约 5 秒完成 1000 帧 IMU 初始化：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch rviz:=true use_camera:=false
```

LIO 平移、旋转和回到起点测试稳定后，再开启 10 Hz 图像输入：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch \
  rviz:=true use_camera:=true image_rate:=10.0
```

为区分 LIVO 的 LiDAR 扫描切片和视觉 EKF 修正，可保持完整 LIVO 数据流但禁止
视觉修改共享位姿：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch \
  rviz:=true use_camera:=true image_rate:=10.0 \
  vio_state_update:=false vio_diagnostics:=true
```

恢复完整视觉融合并保留逐帧诊断：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch \
  rviz:=true use_camera:=true image_rate:=10.0 \
  vio_state_update:=true vio_diagnostics:=true
```

## 10. 录制 FAST-LIVO2 实机输入

一键录制脚本只保存 FAST-LIVO2 实际消费的三个话题：10 Hz 图像、MID-70 点云和
D435i 融合 IMU。数据通过 Docker bind mount 直接写入宿主机，不经过容器可写层：

```bash
cd /home/ufd/cc-chat
./scripts/record_fast_livo_inputs.sh
```

按 `Ctrl+C` 会向 `rosbag record` 发送 `SIGINT` 并等待索引写完。默认输出到
`bags/fast_livo_real/<日期时间>/`，使用 LZ4 压缩和 4 GiB 分卷；剩余空间低于
10 GiB 时自动安全停止。也可以限制录制时间或修改空间阈值：

```bash
./scripts/record_fast_livo_inputs.sh --max-minutes 5 --min-free-gb 15
```

每次录制目录同时包含 `session_metadata.txt`，记录宿主机开始/结束时间、epoch
纳秒、录制器启动后的各传感器连续两帧 header、文件系统空间及停止原因。连续记录
两帧是为了明确区分 D435i 新订阅者收到的首条缓存 IMU 和紧随其后的当前 IMU。

如果 FAST-LIVO2 已经运行，脚本直接录制其
`/camera/color/image_fast_livo`；如果 FAST-LIVO2 未运行，脚本会自动从 30 Hz 原始
图像生成同名的 10 Hz 话题再录制。因此无需为了录包预先启动 SLAM。若需要边跑 SLAM
边录包，应先启动 FAST-LIVO2，再启动录制脚本，以复用已有的图像 throttle。

视觉更新没有线性的“占比”参数。`vio_img_point_cov` 是图像观测协方差，数值越大，
视觉对共享位姿的修正越弱。实机 launch 默认值为 `100`；外参仍在验证时，建议依次
测试 `1000`、`500`、`300`，每轮只修改这一个参数：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch \
  rviz:=true use_camera:=true image_rate:=10.0 \
  vio_state_update:=true vio_diagnostics:=true \
  vio_img_point_cov:=1000
```

诊断行 `[ VIO DIAG ]` 给出视觉候选点、绿/蓝点、更新前后光度 RMSE，以及该次
视觉 EKF 对共享位姿施加的旋转和平移增量。`state_update=OFF` 时位姿增量必须为零。

首次 LIO 静止 30 秒实测：终点平移漂移约 4.2 mm，期间最大偏离约 10.4 mm；
终点姿态变化约 0.16 度，期间最大约 0.78 度。该结果只能证明静态基线正常，仍需
通过分轴平移、旋转、组合运动和回到起点测试评估动态外参与退化问题。

## 11. 手动 LiDAR-Camera 外参调整

独立投影工具、候选参数迭代、备份、验收标准和 LIVO A/B 测试流程见：

```text
/home/ufd/cc-chat/docs/mid70-d435i-manual-extrinsic-calibration.md
```
