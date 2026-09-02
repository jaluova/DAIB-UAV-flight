# 通信环境说明

- 文档版本：2026-09-02（更新：校园网 + USB 热点新拓扑）
- 适用对象：现场实施 / 交付验收 / 网络与链路排障人员
- 配套文档：[domestic-deployment-guide-20260901.md](domestic-deployment-guide-20260901.md)、
  [system-verification-plan-20260901.md](system-verification-plan-20260901.md)

## 1. 目的与范围

本文档描述 DAIB-UAV 系统当前验证过的**通信环境**：网络拓扑、IP/端口清单、控制链路
协议、ROS 通信契约、图传/数传（Foxglove 预览）与排障方法。

如实声明：

- 仓库此前**没有图传（视频回传）与数传（遥测电台）的专项文档**，本文档是现状的首次
  系统梳理；DJI M400 自带的图传/数传链路（O3/OSDK 等）不在本仓库管理范围；
- 控制链路现状为 **Orange Pi 规划器适配器 → UDP 19090 → Manifold PSDK bridge →
  DJI ExecuteJoystickAction**；MAVLink/PX4/XTDrone 模拟时代的通信配置已废弃（附录 A）；
- 当前网络形态为：**香橙派原生网卡接入校内网络（经内网穿透被开发机访问）+
  USB 无线网卡开热点与妙算通信**。旧的家庭局域网拓扑（`192.168.218.x`）已不再适用；
- 文档中「`<尖括号>`」字段为现场实测/固定值，需按现场填入；标注「待现场确认」的项
  是已发现的不一致或动态值，实施时以现场实测为准。

## 2. 总体拓扑

```text
+------------------------------- 校内网络（香橙派原生网卡，DHCP） -------------------------------+
|                                                                                                |
|  香橙派 Orange Pi 5 Max                                                                         |
|    - 原生网卡（校内）：<校内IP>（DHCP，以现场为准）                                               |
|    - USB 无线网卡：AP 热点，SSID <热点SSID>，网段 <热点子网>/24，香橙派侧 <热点网关IP>             |
|                                                                                                |
|  内网穿透（frp 类隧道）：开发机 / 外网 → <frp服务端地址> → 香橙派                                 |
|    转发服务：SSH(22)、镜像仓库(5050)、Foxglove(8765)，具体端口以现场配置为准                     |
+-------------------------------------------------------------------------------------------------+
        |
        | USB AP 热点 Wi-Fi（香橙派 ↔ 妙算专用链路）
        v
  妙算 Manifold 3：Wi-Fi 连接热点，固定 IP <妙算热点IP>
        |
        | UDP 19090 控制链路（20 Hz，DAIB v1 协议）
        +------> DJI M400（ExecuteJoystickAction）

+---- LiDAR 有线隔离网（不变）----+
| enP3p49s0 192.168.1.50/24      |
|        ↔ MID-70 192.168.1.119  |
+---------------------------------+
```

要点：

- **校内网段**承载管理访问（SSH/镜像仓库/Foxglove），开发机不在同一局域网时经
  frp 类隧道访问；香橙派校内地址为 DHCP，地址变化不影响穿透链路（隧道按固定
  服务端地址工作）；
- **USB 热点网段**是香橙派 ↔ 妙算的专用链路：妙算固定 IP，控制链路 UDP 19090
  的目标即该 IP；该网段与校内网、LiDAR 有线网相互隔离；
- **LiDAR 有线隔离网**保持不变，继续承担 MID-70 点云数据链路；
- ROS 通信全部运行在香橙派单机（compose host 网络）内：
  `ROS_MASTER_URI=http://127.0.0.1:11311`、`ROS_HOSTNAME=127.0.0.1`；不存在跨机
  ROS1 TCP 拓扑（旧 Atlas/宿主 RViz 拓扑已废弃）。

## 3. 校内网接入与内网穿透

| 项 | 值 | 说明 |
|---|---|---|
| 香橙派校内接入 | 原生网卡，DHCP | 地址 <校内IP>，以现场 `ip -4 addr` 为准 |
| 内网穿透 | frp 类隧道 | 开发机经 <frp服务端地址> 访问香橙派，隧道两端需保持运行 |
| SSH 访问 | 穿透 SSH(22) 或校内直连 | `ssh orangepi@<穿透地址或校内IP>` |
| 镜像仓库 | 穿透 5050 或离线 rsync | 原局域网仓库 `192.168.218.119:5050` 不再适用（见 §6 历史表） |
| Foxglove | `ws://<穿透地址或校内IP>:8765` | TCP 8765；3D 面板 Fixed Frame 用 `camera_init` |

仓库推进依赖 Mac 侧 `registry:2` 与板端 `insecure-registries` 配置；新拓扑下镜像
传输建议二选一（以现场为准）：① 经穿透暴露 5050 端口后 `docker pull`；②
`rsync --partial` 直接传镜像归档文件后 `docker load`。（板端 `daemon.json` 的
`insecure-registries` 需与穿透地址保持一致。）

## 4. LiDAR 有线网（不变）

| 项 | 值 |
|---|---|
| 香橙派接口 | `enP3p49s0`，`192.168.1.50/24` |
| MID-70 地址 | `192.168.1.119`（广播 code `bd_list:=3GGDLA4001V3191`，`publish_freq:=10.0`） |
| 反向路径过滤 | `rp_filter=0`（`all` 与接口均需设置，RK3588 6.1 内核接收 Livox 限制广播必需） |
| 默认网关 | **不设置**；校内网继续承担管理网络与默认路由 |

配置要点（见 `orange-pi-d435i-mid70-fast-livo-runbook-20260811.md` §6）：

- 必须使用 NetworkManager **持久 profile**，`ip addr` 临时配置无法对抗 NM 恢复；
- 驱动 entrypoint 启动前强制校验地址、到 `192.168.1.119` 的直连路由、源地址与
  `rp_filter` 状态，不匹配则拒绝启动 Livox（防止"ROS 健康但无点云"误判为成功部署）。

**已记录的坑**：曾出现 `192.168.1.119 via 192.168.218.186 dev wlan0 src 192.168.218.200`
的错误路由——根因是 NM 默认把 LiDAR 地址当远程主机绕行 Wi-Fi，不是 Livox SDK 或
`rp_filter` 问题。新拓扑下避免在承载热点的 USB 无线接口或校内网卡上出现到
`192.168.1.119` 的路由即可。检查命令：

```bash
ip -4 route get 192.168.1.119     # 期望 dev enP3p49s0 src 192.168.1.50
cat /proc/sys/net/ipv4/conf/all/rp_filter
cat /proc/sys/net/ipv4/conf/enP3p49s0/rp_filter
```

## 5. 控制链路（规划器 → UDP → PSDK → DJI）

```text
Orange Pi: /daib_ego/position_cmd → psdk_velocity_adapter → /psdk/velocity_command
    → (udp_enabled:=true) UDP 包 20 Hz → 妙算热点内 <妙算热点IP>:19090 → PSDK bridge → DJI
```

### 5.1 报文格式（DAIB v1，见 `docs/psdk-udp-bridge-ground-test.md`）

- 魔数 `DAIB`、版本、类型、**CRC32**、序号、µs 时间戳、`{x[m/s], y[m/s], z[m/s], yaw[deg/s]}` 四个 float32；
- 发送频率 20 Hz；接收端 **200 ms 无有效包 → 输出 NEUTRAL `{0,0,0,0}`**（保护动作）；
- 限幅（联调阶段）：水平 `0.1`、垂直 `0.05`、yaw `0` m/s/deg/s；适配器默认限制为
  `0.5 / 0.2 / 3 deg/s`；yaw 为目标角与 odom 机头角的闭环输出（`psdk-planner-adapter.md`）；
- 适配器 UDP 默认**关闭**（`udp_enabled:=false`，`udp_host:=127.0.0.1`，`udp_port:=19090`）；
  只有通过地面干跑验证后才允许打开并指向妙算热点 IP；
- 参考实现：`tools/psdk_velocity_udp_receiver.py`（只校验不调用 DJI API）、
  `src/DAIB-Planner/src/planner/psdk_velocity_adapter/`。

### 5.2 权限状态机（Manifold 侧 Demo 菜单）

| 键 | 行为 | 日志 |
|---|---|---|
| `M` | 获取 PSDK joystick 控制权 | `PSDK authority confirmed; state=ACTIVE` |
| `U` | 解除 live output 并释放控制权 | `Normal release confirmed; state=IDLE` |
| `L` | 武装 DJI API 输出（不单独取权） | 仅 `L=armed` 且 `ACTIVE` 才 20 Hz 调用 API |
| `A` | 确认 ABORTED 并回到 IDLE | RC 夺权/Pause 后按 `A` 确认 |
| `Q` | 退出菜单 | — |

## 6. IP / 端口全量清单

### 6.1 当前拓扑

| 角色 | 地址 | 说明 |
|---|---|---|
| 香橙派（校内网） | `<校内IP>`（DHCP） | 原生网卡；地址变化不影响穿透链路 |
| 香橙派（热点侧） | `<热点网关IP>`（`<热点子网>/24`） | USB 无线网卡 AP；现场固定 |
| 妙算（热点内） | `<妙算热点IP>`（固定） | **控制链路 UDP 19090 的目标**，现场固定 |
| 内网穿透 | `<frp服务端地址>` | 转发 SSH / 镜像仓库 / Foxglove，端口以现场为准 |
| LiDAR 网 | `192.168.1.50/24 ↔ 192.168.1.119` | 不变 |

### 6.2 历史地址（旧拓扑，不再适用）

| 角色 | 地址 | 状态 |
|---|---|---|
| 香橙派管理 | `192.168.218.200`（家庭局域网） | 旧拓扑，废弃 |
| 开发机 / 局域网仓库 | `192.168.218.119:5050` | 旧拓扑，废弃（新方式见 §3） |
| 妙算 Wi-Fi DHCP | `10.82.172.53`（家庭路由器） | 旧接入方式，废弃 |
| 妙算 USB RNDIS | `192.168.42.140` | 改为热点固定 IP |
| 妙算联调值 | `192.168.177.53` | 旧联调值，废弃 |
| 妙算（**疑似过期**） | `192.168.60.210`（仅 `scripts/tmux-flight.conf`） | **新拓扑下应改为妙算热点 IP，待现场修正** |

端口清单（不变）：

| 端口 | 协议 | 用途 |
|---|---|---|
| 19090 | UDP | 控制链路（香橙派 → 妙算，经 USB 热点） |
| 8765 | TCP | Foxglove WebSocket（经穿透或校内直连） |
| 11311 | TCP | ROS1 Master（单机 host 网络，127.0.0.1） |
| 5050 | TCP | 镜像仓库（新拓扑建议穿透暴露或离线加载） |
| 22 | TCP | SSH（香橙派、妙算） |

容器名注意：compose 默认生成 `deploy-roscore-1` / `deploy-algorithm-1` / `deploy-drivers-1`
（前缀随 compose 项目名）；历史文档中的 `daib-sensor-master`、`daib-drivers`、
`daib-algorithm`、`daib-algorithm-adapter` 为旧命名/遗留配置（`tmux-flight.conf` 即使用
旧名 `daib-algorithm-adapter`）。执行时一律 `docker ps` 以实际容器名为准。

## 7. ROS 通信契约（话题清单）

### 7.1 当前话题

| 层 | 话题 | 类型/频率 |
|---|---|---|
| 传感器 | `/livox/lidar` | `livox_ros_driver/CustomMsg` ~10 Hz |
| 传感器 | `/camera/imu` | ~200 Hz（D435i fused IMU） |
| 传感器 | `/camera/color/image_raw` | ~30 Hz 原始图像 |
| 传感器 | `/camera/color/image_fast_livo` | ~10 Hz，算法实际消费 |
| 传感器 | `/camera/color/image_fast_livo_foxglove` | 6 Hz（默认）远程预览，不入 bag |
| SLAM | `/daib_slam/odom` | `camera_init` 世界系 |
| SLAM | `/daib_slam/planning_cloud` | SLAM → Explorer 的点云输入 |
| Explorer | `/daib_explorer/ready` / `state` / `generation` | 状态与目标代数 |
| Explorer | `/daib_explorer/goal` | **latched**；目标点 |
| Explorer | `/daib_explorer/frontiers` / `selected_cluster_frontiers` | 边界与来源 cluster |
| Explorer | `/daib_explorer/planning_cloud` | 提供给 EGO 的占据点云 |
| EGO | `/drone_0_ego_planner_node/goal_point` / `optimal_list` | 目标 Marker / 局部轨迹（视距默认 7.5 m） |
| EGO | `/drone_0_ego_planner_node/grid_map/occupancy_inflate` | 膨胀障碍地图 |
| Bridge | `/daib_ego/goal` | **latched**；Explorer → EGO 目标 |
| Bridge | `/daib_ego/bridge_state` / `accepted_generation` | 转发状态 / 已接受代数 |
| 规划 | `/daib_ego/position_cmd` | `quadrotor_msgs/PositionCommand`（traj_server） |
| 适配 | `/psdk/velocity_command` | `geometry_msgs/TwistStamped` 20 Hz（`angular.z` 为 rad/s） |
| 适配 | `/psdk/yaw_control_debug` / `velocity_direction_dji_world` / `odom_corrected` | 调试箭头 / 校正 odom |
| DJI | `/psdk/dji_command_xyz_yaw` | 发送给 bridge 的最终 `{x,y,z,yaw}` |
| 隔离 | `/daib_observe/position_cmd_unconnected` | 观察模式隔离话题（脚本确认无订阅者） |

### 7.2 已知语义细节

- `/daib_explorer/goal` 与 `/daib_ego/goal` 均为 latched：即使 Explorer 内部撤销目标，
  若没有显式 `goal_valid=false` 或 Marker `DELETE` 协议，Foxglove/新订阅者仍会看到旧坐标
  （基线文档记录的问题，修复方案见基线 2026-08-12 节）；
- 观察模式（`start_explorer_planning_observe.sh` / `start_bag_play.sh --explorer-observe`）
  不启动任何飞控/SDK，仅确认隔离话题无订阅者后输出 `[PASS]`。

### 7.3 禁用旧话题（历史遗留，禁止用于当前判断）

```text
/daib_slam/imu_odom            （旧 SLAM 输出命名）
/daib_px4/*                    （PX4 桥）
/iris_0/mavros/*  /xtdrone/*   （XTDrone 模拟链路）
/aft_mapped_to_init            （旧 FAST-LIVO 输出名）
planning_cloud_px4_bridge      （旧桥）
```

当前话题名以板端实际 `roslaunch` 文件与 `rostopic list` 输出为准，不要从旧文档复制。

## 8. 图传与数传（现状说明）

- **图传（视频回传）**：当前形态为 Foxglove WebSocket（TCP 8765）承载的相机预览：
  飞行模式使用 6 Hz 相机流（`/camera/color/image_fast_livo_foxglove`，4 MB 发送缓冲，
  拥塞时丢帧优先而非累积延迟），观察/回放模式使用全话题流。远程访问方式为
  `ws://<穿透地址或校内IP>:8765`。带宽注意：30 Hz 原始图像不适合默认远程推送或录制；
  校园网/穿透链路带宽不足时优先保留 `/cloud_registered` 等点云与状态流，图像降频。
- **数传（遥测电台）**：仓库内无电台/串口数传配置与文档（MAVLink 串口参数在仓库中
  无任何配置）；DJI M400 自带遥控链路与图传不在此文档范围。
- 需要正式的图传/数传（含带宽预算与天线部署）章节时，需依据现场设备型号补充编写，
  本指南不臆造未验证内容。

## 9. 排障指引

| 现象 | 检查 |
|---|---|
| 到妙算不通（控制链路） | 香橙派 `ping -c 10 <妙算热点IP>`；`ip route get <妙算热点IP>`（应走热点接口）；确认妙算 Wi-Fi 已连接热点 SSID |
| 控制链路收不到包 | 香橙派 `docker logs --tail 50 <算法容器>`；妙算 `ss -lunp \| grep 19090`；确认只有**一个**监听者（Python dry-run / C++ bridge 互斥） |
| 端口占用 | `sudo ss -lunp \| grep 19090`，关掉多余接收器 |
| SSH / Foxglove / 仓库连不上（远程） | 先 `ping <frp服务端地址>`，再检查香橙派 frp 客户端进程是否运行；最后确认对应转发端口 |
| 校内地址变了 | 隧道按固定服务端地址工作不受影响；SSH 直连场景以现场 `ip -4 addr` 为准 |
| LiDAR 路由错误 | `ip -4 route get 192.168.1.119`（期望 `dev enP3p49s0`）；NM 持久 profile 重建，不要手工 `ip addr` |
| `sequence_gap` | 先 `U` 停止真实 API 输出；检查热点 Wi-Fi 信号、CPU 负载与是否有人占用了热点带宽；持续丢包不允许继续飞行 |
| `NEUTRAL reason=timeout` | 保护动作：超过 200 ms 无有效包。恢复 adapter/ROS/链路后再重新走权限流程 |
| `ABORTED` | 控制权已离开 PSDK（RC 切模式/Pause 等）。保持 RC 接管，确认安全后按 `A`，**不要**直接重按 `L/M` |
| Foxglove 连不上 | 确认地址为穿透地址或校内 IP、端口 8765、Fixed Frame `camera_init`；`ENABLE_FOXGLOVE=true` |
| 板端时钟偏移 | 无硬件 RTC：启动脚本自动恢复最近已知正确时钟并告警；现场建议部署 NTP/chrony |

## 10. 参考文档

- [psdk-udp-bridge-test-procedure-20260826.md](psdk-udp-bridge-test-procedure-20260826.md) —— 链路联调流程与通过标准
- [psdk-udp-bridge-ground-test.md](psdk-udp-bridge-ground-test.md) —— 报文协议细节（CRC/seq/超时）
- [psdk-planner-adapter.md](psdk-planner-adapter.md) —— 适配器转换与限幅
- [manifold3-m400-psdk-handoff-20260822.md](manifold3-m400-psdk-handoff-20260822.md) —— Manifold 接入方式（热点接入后以本文档 §6 为准）
- [orange-pi-d435i-mid70-fast-livo-runbook-20260811.md](orange-pi-d435i-mid70-fast-livo-runbook-20260811.md) —— LiDAR 组网与路由坑（§6）
- [flight-quickstart-README.md](flight-quickstart-README.md) —— 启动/观察/录包
- [exploration-run-recording-plan.md](exploration-run-recording-plan.md) —— 录包话题分层
- [planner-dji-runtime-safety-handoff-20260810.md](planner-dji-runtime-safety-handoff-20260810.md) —— 话题契约对照（新旧）

## 附录 A：旧通信配置对照（废弃，仅标注）

| 旧配置 | 内容 | 弃用理由 |
|---|---|---|
| `docs/dds-communication.md` | ROS2 FastDDS host↔Atlas（192.168.0.101 ↔ 192.168.0.2、端口 7400、`ROS_DOMAIN_ID=1`、peer XML、代理 172.21.100.48） | ROS2/Atlas 时代；当前为 ROS1 单机容器栈 |
| `docs/host-ros1-rviz.md` | 宿主 RViz ↔ Atlas（`ROS_MASTER_URI=http://192.168.0.2:11311`、/etc/hosts `davinci-mini`） | Atlas 时代；已由板端 Foxglove 取代 |
| `docs/huawei-usb-tether.md` | Huawei Atlas USB RNDIS（192.168.0.101/24→192.168.0.2） | Atlas 专用 |
| `docs/gazebo-simulation.md` | 宿主↔Atlas 仿真拓扑 | 仿真链路废弃 |
| `docs/current-indoor3-livo-ego-multiterminal-20260803.md` 等 indoor3/XTDrone/MAVROS 文档 | `/iris_0/mavros/*`、`multirotor_communication.py`、`cmd_pose_enu` 等模拟链路 | MAVLink 模拟链路被 DJI PSDK UDP 链路取代；仓库无 PX4/MAVLink 实机配置 |
| 旧 IP 段 `192.168.0.x`、`172.21.100.48`、`192.168.218.x` | Atlas/代理时代及家庭局域网时代地址 | 与当前两网段（校内 + 热点）无交集，禁止在新环境使用 |

## 附录 B：待现场确认项（不修改文件，仅标注）

1. **热点网段与妙算固定 IP 具体数值**：本文档以 `<热点子网>/24`、`<热点网关IP>`、
   `<妙算热点IP>` 占位，需按香橙派 USB 热点实际配置填入（妙算 IP 为固定分配）；
2. **frp 穿透参数**：`<frp服务端地址>` 及实际转发的服务端口（SSH / 镜像仓库 /
   Foxglove）需按现场配置填入，并同步更新香橙派 frp 客户端配置；
3. **`scripts/tmux-flight.conf` 的 `udp_host`**：当前值为 `192.168.60.210`（历史遗留，
   与任何现网地址不符），新拓扑下应改为妙算热点 IP `<妙算热点IP>`；使用
   `start_tmux_flight.sh` 前必须修正；
4. **镜像仓库传输方式**：穿透暴露 5050 与离线 `rsync` + `docker load` 二选一，
   以现场网络条件为准；选定后更新香橙派 `daemon.json` 的 `insecure-registries`；
5. **妙算接入方式已统一**：原 wlan0 DHCP（家庭路由器）与 USB RNDIS 描述为历史，
   当前唯一接入方式为 USB 热点 Wi-Fi（固定 IP）；
6. **容器名历史遗留**：`daib-algorithm` / `deploy-algorithm-1` / `daib-algorithm-adapter`
   并存于不同文档与配置，统一以 `docker ps` 实际名为准，并建议后续把旧名配置收敛到
   compose 实际命名。