# 国产化部署指南（openEuler ARM64 容器化部署）

- 文档版本：2026-09-01
- 适用对象：现场实施 / 交付验收 / 后续维护人员
- 对应代码基线：`sync_yyy`（具体子模块提交与算法镜像 ID 以 `CURRENT_SYNC_YYY_BASELINE.md` 为准）

## 1. 文档目的与范围

本文档描述 DAIB-UAV 系统的**国产化部署形态**：

```text
国产 ARM64 硬件（Orange Pi 5 Max，RK3588）
    + 国产基础软件容器用户态（openEuler 24.03 LTS SP4）
    + ROS1 Noetic + FAST-LIVO2 / EGO-Planner / DAIB-Explorer
```

当前仓库所有实机功能测试、启动命令和参数判断均以本部署形态为唯一运行基线
（见 [CURRENT_SYNC_YYY_BASELINE.md](CURRENT_SYNC_YYY_BASELINE.md)）。

部署形态说明（如实声明）：

- 容器用户态为 openEuler 24.03 LTS SP4，是信创操作系统目录中的主流发行版之一；
- 宿主操作系统为 Orange Pi Ubuntu 22.04.4 LTS（ARM64），仅提供 Rockchip 内核、
  引导与 Docker 运行时，不承载 ROS 与算法；
- 处理器为 RK3588（ARMv8-A，aarch64），当前镜像为 CPU-only，不包含 RK3588
  GPU/NPU 运行时；
- 麒麟、统信等其它信创操作系统**未经验证**，本指南不覆盖。

## 2. 系统组成

| 组件 | 内容 |
|---|---|
| `daib-algorithm:openeuler-arm64` | ROS Master（roscore）、FAST-LIVO2、EGO-Planner、DAIB-Explorer、Foxglove Bridge、离线 bag 回放 |
| `daib-drivers:openeuler-arm64` | D435i / librealsense（RSUSB 后端）、Livox MID-70 驱动 |
| 基础镜像 | `openeuler/openeuler:24.03-lts-sp4` + ROS Noetic |
| Compose 服务 | `roscore`、`algorithm`、`drivers` 三个服务，host 网络模式 |

两个镜像共享宿主 Rockchip 内核；容器提供各自的 openEuler 用户态。

## 3. 交付物清单

构建机（Apple Silicon Mac）产出：

| 产物 | 说明 |
|---|---|
| `dist/daib-openeuler-arm64-images.tar.gz` + `.sha256` | 两镜像全量包（gzip） |
| `dist/daib-algorithm-openeuler-arm64.tar.zst` + `.sha256` | 仅算法镜像增量包（zstd，可直接 `docker load`） |
| `deploy/` 目录 + 配置好的 `.env` | 板端 compose 与配置模板 |

板端镜像引用（`.env`）：

```dotenv
ALGORITHM_IMAGE=daib-algorithm:openeuler-arm64
DRIVERS_IMAGE=daib-drivers:openeuler-arm64
```

从 LAN 镜像仓库拉取时：

```dotenv
ALGORITHM_IMAGE=192.168.218.119:5050/daib-algorithm:openeuler-arm64
```

## 4. 硬件与网络前置条件

### 4.1 板端硬件

- Orange Pi 5 Max（RK3588 / aarch64），内存 ≥ 8 GiB（验证板为 7.7 GiB + 3.9 GiB swap）；
- NVMe SSD ≥ 40 GiB 可用空间（验证板 117 GiB，挂载于 `/mnt/ssd`），Docker 数据与运行数据均放 NVMe；
- 传感器：Livox MID-70（广播 code `3GGDLA4001V3191`）+ RealSense D435i。

### 4.2 网络三段

| 网段 | 接口 / 地址 | 用途 |
|---|---|---|
| 管理网络 | `wlan0`，香橙派 `192.168.218.200/24` | SSH、Foxglove、镜像仓库拉取 |
| LiDAR 有线网 | `enP3p49s0`，香橙派 `192.168.1.50/24` ↔ MID-70 `192.168.1.119` | Livox 点云（独立网段，不设默认网关） |
| 镜像仓库 / 开发机 | Mac `192.168.218.119:5050` | 镜像增量传输 |

网络细节与排障见 [communication-environment-guide-20260901.md](communication-environment-guide-20260901.md)
（本指南只给部署必需的配置）。

## 5. 镜像构建（开发机侧）

### 5.1 准备干净源码归档

在仓库根目录执行：

```bash
./deploy/scripts/package-build-context.sh
```

归档排除 bag、备份、Git 元数据、仿真资产、日志与生成文件（与 `.dockerignore` 一致）。

### 5.2 构建代理

Docker Desktop 必须使用本机代理 `http://127.0.0.1:7897`（macOS 系统代理需同时开启 HTTP/HTTPS），
构建脚本再以 `DAIB_BUILD_PROXY=http://host.docker.internal:7897` 传给 DNF/Git/构建步骤。
容器内不要用 `127.0.0.1:7897`（回指容器自身）。

### 5.3 构建命令

```bash
BUILD_JOBS=1 ./deploy/scripts/build-openeuler-arm64-images.sh      # 两镜像全量
BUILD_JOBS=1 ./deploy/scripts/build-algorithm-image.sh             # 仅算法镜像
```

- 输出分别为 `dist/daib-openeuler-arm64-images.tar.gz` 与 `dist/daib-algorithm-openeuler-arm64.tar.zst`（均带 SHA-256 文件）；
- 原生 `linux/arm64` 构建，PCL/ROS/驱动编译耗时很长；8 GiB 板端与约 4 GiB 内存的 Docker Desktop VM 上保持 `BUILD_JOBS=1`。

## 6. 板端环境准备

### 6.1 初次检查

```bash
uname -m          # 必须为 aarch64 / arm64
docker version    # 需安装 Docker Engine + Buildx + Compose 插件
free -h           # ≥ 8 GiB RAM
df -h             # ≥ 40 GiB 剩余（NVMe 优先）
ip -br link
lsusb
```

### 6.2 NVMe 与 Docker 数据目录

```bash
findmnt /mnt/ssd
docker info --format '{{.DockerRootDir}}'      # 期望 /mnt/ssd/docker
systemctl show docker -p After -p RequiresMountsFor
```

- `/mnt/ssd` 必须在 `/etc/fstab` 持久挂载，否则 NVMe 未就绪时 Docker 会写 SD 卡目录；
- 不要覆盖 `daemon.json` 中已有的其他配置（如 `insecure-registries` 需合并）。

## 7. 镜像传输与加载

### 7.1 全量 / 增量包加载

```bash
# 开发机 → 板端（rsync 可断点续传）
rsync -ahP dist/daib-algorithm-openeuler-arm64.tar.zst orangepi@192.168.218.200:/mnt/ssd/

# 板端校验并加载
cd /mnt/ssd
sha256sum daib-algorithm-openeuler-arm64.tar.zst
docker load -i daib-algorithm-openeuler-arm64.tar.zst
docker image inspect daib-algorithm:openeuler-arm64 \
  --format 'ID={{.Id}} ARCH={{.Architecture}} SIZE={{.Size}}'
```

### 7.2 LAN 镜像仓库（增量更新推荐）

仓库运行在 Mac `192.168.218.119:5050`（5000 被 macOS AirPlay 占用，故用 5050）：

```bash
docker volume create daib-registry-data
docker run -d --name daib-registry --restart unless-stopped \
  -p 5050:5000 -v daib-registry-data:/var/lib/registry registry:2
curl http://192.168.218.119:5050/v2/     # 返回 {}
```

板端 `/etc/docker/daemon.json` **合并**（不要覆盖 `data-root`）：

```json
{
  "insecure-registries": ["192.168.218.119:5050"]
}
```

推送与拉取：

```bash
# 开发机
docker tag daib-algorithm:openeuler-arm64 localhost:5050/daib-algorithm:openeuler-arm64
docker push localhost:5050/daib-algorithm:openeuler-arm64

# 板端
sudo systemctl restart docker
docker pull 192.168.218.119:5050/daib-algorithm:openeuler-arm64
```

`docker pull` 只传输内容摘要变化的层，适合迭代。`192.168.218.119` 建议在 DHCP 中保留给 Mac。

## 8. 板端部署配置

### 8.1 Compose 栈

```bash
docker compose --env-file deploy/.env -f deploy/compose.orange-pi-5-max.yml up -d --no-build
docker compose --env-file deploy/.env -f deploy/compose.orange-pi-5-max.yml logs -f
```

服务：`roscore`（持久 ROS Master）→ `algorithm` → `drivers`（privileged，host 网络）。

### 8.2 `.env` 关键配置

| 变量 | 验证值 | 说明 |
|---|---|---|
| `DATA_DIR` / `BAGS_DIR` | `/mnt/ssd/data` / `/mnt/ssd/bags` | 挂载为容器内 `/data` 与 `/bags`（只读） |
| `CONFIGURE_LIDAR_INTERFACE` | `true` | 启动时配置 LiDAR 有线口 |
| `CONFIGURE_LIDAR_RP_FILTER` / `VERIFY_LIDAR_RP_FILTER` | `true` | `rp_filter=0`（all + 接口） |
| `LIDAR_INTERFACE` | `enP3p49s0` | 物理接口 |
| `LIDAR_HOST_CIDR` | `192.168.1.50/24` | 香橙派侧地址 |
| `LIDAR_DEVICE_IP` | `192.168.1.119` | MID-70 地址 |
| `LIVOX_ARGS` | `bd_list:=3GGDLA4001V3191 publish_freq:=10.0` | 广播码与频率 |
| `REALSENSE_FORCE_RSUSB_BACKEND` | `ON` | RSUSB 后端，不依赖宿主 UVC 补丁 |
| `ALGORITHM_LAUNCH` | `fast_livo mapping_mid70_d435i.launch rviz:=false use_camera:=false` | LIO-only 默认 |
| `ENABLE_FOXGLOVE` / `FOXGLOVE_PORT` | `true` / `8765` | Foxglove WebSocket |
| `BAG_FILE` | 空 | 留空为实机模式 |

物理接口或 LiDAR 网段变化时才需要覆盖以上 LiDAR 值。

### 8.3 LiDAR 网络校验

驱动 entrypoint 在启动 Livox 前强制校验：有线地址、到 `192.168.1.119` 的路由、源地址、
`rp_filter` 状态，全部匹配才允许启动——避免"ROS 进程健康但无点云"被误判为部署成功。

仅验证宿主侧 LiDAR 网络（不启动驱动）：

```bash
# 以 LIDAR_NETWORK_PREFLIGHT_ONLY=true 运行 drivers 镜像
# 输出 LiDAR network preflight passed 后退出
```

## 9. 启动与部署自检

在板端仓库根目录（`/mnt/huawei_ssd/daib`）执行以下脚本（详见
[flight-quickstart-README.md](flight-quickstart-README.md)）：

```bash
./scripts/start_lio_only.sh --check-seconds 15        # MID-70 + D435i IMU，相机不参与
./scripts/start_livo.sh --check-seconds 15            # 正常 LIVO（含彩色图像）
./scripts/start_flight_stack.sh --check-seconds 15 --camera-rate 6   # 飞行栈 + 低延迟相机流
./scripts/start_explorer_planning_observe.sh --check-seconds 15 --camera-rate 8  # + Explorer/EGO 观察
./scripts/stop_daib_stack.sh                          # 停止
```

关键行为：

- 脚本会校验 LiDAR/IMU/图像频率与时间戳对齐，通过后输出 `[PASS] LIO-only stack is ready`；
- 板端无硬件 RTC：脚本先做时钟检查（chrony/NTP，不可用则恢复最近已知正确时钟并告警）；
- 重复启动只重建 `algorithm`，复用 `roscore` 与健康的 `drivers` 容器，不打断 D435i 的 USB/UVC 会话；
- 所有启动脚本**不启动** PX4/MAVROS offboard、SDK/控制器或自主避障控制。

部署自检阈值（`deploy/scripts/check_sensor_timing.py`）：

| 检查项 | 阈值 |
|---|---|
| LiDAR 频率 | 8.0–12.0 Hz |
| LiDAR 每帧点数（中位数） | ≥ 9000 |
| LiDAR 扫描周期（中位数） | 80–120 ms |
| LiDAR 扫描结束到达滞后（中位数） | −20..80 ms |
| IMU 频率 | 150–260 Hz |
| IMU 到达-时间戳滞后（中位数） | −20..80 ms |
| IMU 最近邻 LiDAR 时间差 p95 | ≤ 10 ms |
| 图像频率（默认） | 25–35 Hz |
| 图像到达-时间戳滞后（中位数） | −20..120 ms |
| 图像最近邻 LiDAR 时间差 p95 | ≤ 25 ms |
| 时间戳回退 | 0 次 |

完整分层验收流程见 [system-verification-plan-20260901.md](system-verification-plan-20260901.md)。

## 10. 部署验收清单

以下条目全部满足才视为部署完成：

- [ ] `uname -m` 为 `aarch64`；Docker Engine/Compose 可运行
- [ ] `docker info` 的 DockerRootDir 为 `/mnt/ssd/docker`，NVMe 已持久挂载
- [ ] 两镜像 `docker load` 成功，`docker image inspect` 的 ARCH 为 arm64
- [ ] `.env` 中 LiDAR 接口/网段与实际物理链路一致；`daemon.json` 已合并 `insecure-registries`（如走仓库）
- [ ] LiDAR 网络 preflight 通过（`LiDAR network preflight passed`）
- [ ] `start_lio_only.sh` 输出 `[PASS] LIO-only stack is ready`（含时钟检查）
- [ ] `rostopic hz /daib_slam/odom` 有数据，frame 为 `camera_init`
- [ ] Foxglove 可连 `ws://<香橙派IP>:8765`，3D 面板 Fixed Frame 用 `camera_init`
- [ ] 记录本次**镜像标签 + image ID**（只写 `openeuler-arm64` 不能唯一确定测试内容）

## 11. 已知风险与注意

1. **openEuler ROS 仓库为 TEST1 未发版**：ROS Noetic RPM 仓库（
   `ROS-SIG-Multi-Version_ros-noetic_openEuler-24.03-LTS-TEST1`）依赖完整、兼容补丁
   （Poco 1.12.4、`python3-` 前缀命令、`ddynamic_reconfigure` 从固定 tag 源码构建）。
   仓库一旦更新或下线，需同步更新 `deploy/scripts/install-openeuler-ros.sh` 后重建镜像。
2. **镜像标签会重推**：一次实验记录必须同时写明镜像标签与 image ID；新算法镜像发布前，
   板端旧镜像仍按旧接口使用（见基线文档）。
3. **外参绑定物理安装**：`mid70_d435i.yaml` 等标定文件针对当前传感器安装方式，
   改动传感器支架后必须重新标定（见 [mid70-d435i-manual-extrinsic-calibration.md](mid70-d435i-manual-extrinsic-calibration.md)）。
4. **硬件能力**：CPU-only，无 GPU/NPU 加速；板端算力受限时按
   `BUILD_JOBS=1`、Explorer 动态预算策略保守配置。
5. **128 GiB 以下容量注意**：录包与镜像并存需 ≥ 40 GiB；录制 59.1 s 实测约 1.1 GiB。

## 12. 参考文档

- [deploy/README.md](../deploy/README.md) —— 构建/加载/仓库/启动的权威说明
- [orange-pi-5-max-board-info.md](orange-pi-5-max-board-info.md) —— 板端硬件与路径事实
- [orange-pi-5-max-container-worklog-20260809.md](orange-pi-5-max-container-worklog-20260809.md) —— 迁移与镜像验证记录
- [orange-pi-d435i-mid70-fast-livo-runbook-20260811.md](orange-pi-d435i-mid70-fast-livo-runbook-20260811.md) —— 硬件/驱动现场手册
- [CURRENT_SYNC_YYY_BASELINE.md](CURRENT_SYNC_YYY_BASELINE.md) —— 唯一运行基线声明
- [memory/lan-docker-registry.md](memory/lan-docker-registry.md) —— 仓库运维
- [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md) —— 目录说明

## 附录 A：旧配置对照表（禁用 / 仅历史参考）

以下内容**不是当前部署形态**，禁止直接复制其中命令作为当前启动/判断依据；
只保留作历史记录，不删除、不迁移。

| 旧配置 | 内容 | 判定与理由 |
|---|---|---|
| `docs/atlas-board-info.md` | Atlas 200I DK A2（openEuler 22.03 宿主、Docker 18.09、`ros1_dev`/`ros2_dev` 容器） | 已淘汰平台；`memory/MEMORY.md` 明确"不应直接当作香橙派配置" |
| `docs/huawei-usb-tether.md` | Atlas USB RNDIS 组网 | Atlas 专用，已淘汰 |
| `docs/dds-communication.md` | ROS2 FastDDS ↔ Atlas 组网（192.168.0.x） | ROS2 时代路径，当前为 ROS1 容器栈 |
| `docs/host-ros1-rviz.md` | 宿主 Ubuntu 20.04 RViz ↔ Atlas | 已被板端 Foxglove 取代 |
| `docs/gazebo-simulation.md` | Ubuntu 20.04 x86 Gazebo 11 仿真容器 | 非国产化链，且仿真链路已不再作为当前依据 |
| `docs/memory/atlas-board-ssd.md` / `docs/memory/docker-data-root.md` | Atlas NVMe `/data`、Docker data-root `/data/docker` | 板端路径已改为 `/mnt/ssd/docker` |
| `docs/local-d435i-mid70-drivers.md` | 旧 x86 Ubuntu 双容器驱动环境 | 文档自标"仅保留作历史排障参考" |
| `deploy/Dockerfile.realsense-ubuntu` + `deploy/scripts/build-realsense-ubuntu-arm64-image.sh` | Ubuntu focal（`ros:noetic-ros-base-focal`）RealSense A/B 镜像 | 已被 openEuler `daib-drivers` 镜像取代；当前 compose 不引用 |
| `deploy/scripts/build-arm64-images.sh` | 旧构建脚本 | 已是 deprecated 桩：打印提示后转调 `build-openeuler-arm64-images.sh` |
| `docs/fastlivo2-openeuler-summary.md` / `docs/fastlivo2-compile-guide.md` / `docs/ego-planner-build-notes.md` | Atlas 时代 openEuler 构建排错记录 | 其中的 OS 依赖/兼容知识可作构建参考，但设备路径与命令不能直接用 |
| 名称含 `gpsless-cleanup-*`、`feature/gpsless-*` 的镜像/容器/脚本 | 旧分支产物 | 基线文档明确不再作为当前依据 |