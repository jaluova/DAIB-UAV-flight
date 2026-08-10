# Orange Pi 5 Max 容器化工作记录

更新日期：2026-08-10

## 目标与结论

本轮工作将原有部署方案调整为 Orange Pi 5 Max，并在 Apple Silicon Mac
上构建供板卡运行的 ARM64/openEuler 容器。板卡当前宿主系统为 Orange Pi
Ubuntu 22.04.4 LTS，这不影响运行 openEuler 用户态镜像：容器使用
openEuler 24.03 LTS SP4 用户态并共享 Ubuntu 宿主机的 Rockchip ARM64 内核。

正式部署保留两个容器：

- `daib-algorithm:openeuler-arm64`：ROS master、FAST-LIVO2、EGO-Planner、
  DAIB-Explorer、Foxglove Bridge 和离线 rosbag 回放。
- `daib-drivers:openeuler-arm64`：D435i/librealsense 和 Livox MID-70 驱动。

Foxglove Bridge 已集成进算法镜像，不再维护单独的第三个 Foxglove 镜像。
临时讨论过的 `view -> camera_init` 静态坐标变换尚未实现；Foxglove 3D
面板当前应直接使用 `camera_init` 作为 Fixed Frame。

## 板卡环境

已确认的板卡环境：

| 项目 | 当前值 |
|---|---|
| 板卡 | Orange Pi 5 Max / RK3588 |
| 架构 | `aarch64` |
| 宿主系统 | Orange Pi 1.0.0 / Ubuntu 22.04.4 LTS |
| 内核 | `6.1.43-rockchip-rk3588` |
| 内存 | 7.7 GiB RAM、3.9 GiB swap |
| Docker | 27.0.3、cgroup v2、overlay2 |
| Compose | 5.4.0 |
| Wi-Fi | `wlan0` / `192.168.218.200/24` |
| NVMe | `/mnt/ssd`，约 93 GiB 可用 |
| Docker data-root | `/mnt/ssd/docker` |
| 数据目录 | `/mnt/ssd/data` |
| bag 目录 | `/mnt/ssd/bags` |
| 有线接口 | `enP3p49s0` |

Livox 与 D435i 的最终硬件连接信息尚未完全确认。连接 Livox 后需要核实
其子网和板卡有线地址；在此之前保持 `CONFIGURE_LIDAR_INTERFACE=false`。
D435i 应连接 USB 3.0 端口并用 `lsusb` 确认识别。

## 已完成实现

算法镜像增加了以下能力：

- Foxglove Bridge 0.8.5，默认监听 TCP 8765。
- `ros_babel_fish` 0.9.3 和 websocketpp 0.8.2。
- 最小化 `livox_ros_driver` 消息包，使 Foxglove 能发现并解析
  `livox_ros_driver/CustomMsg`。
- `python-gnupg`，修复 openEuler 环境中 `rosbag` 的 Python 依赖。
- 可选 bag 模式：`BAG_FILE`、`BAG_RATE`、`BAG_DELAY` 和 `BAG_LOOP`。
- `/mnt/ssd/bags` 以只读方式挂载到容器 `/bags`。
- 修复多个 catkin workspace 互相覆盖的问题；Foxglove workspace 通过
  `setup.bash --extend` 叠加，因此 FAST-LIVO 和 Foxglove 包可同时发现。

主要实现文件：

- `deploy/Dockerfile.algorithm`
- `deploy/scripts/algorithm-entrypoint.sh`
- `deploy/scripts/build-algorithm-image.sh`
- `deploy/compose.orange-pi-5-max.yml`
- `deploy/.env.example`
- `deploy/ros/livox_ros_driver/`

## 当前构建产物

构建目录：`dist/`

| 文件 | 大小 | SHA-256 |
|---|---:|---|
| `daib-algorithm-openeuler-arm64.tar.zst` | 784 MiB | `fdcd20c45267181e6f600b5e05dd22b836c2b249ec9e047d6b17c44a55810a31` |
| `daib-drivers-openeuler-arm64.tar.gz` | 815 MiB | `f07eba519769f0478e0ac514a0fbe181b6ef9a53044bcd2cdebeedee30f02c14` |

当前算法镜像 ID 为
`sha256:9cae8d1c0af881790956c60eacad05768a2f58c7ba9f29609866653e8d108f07`，
平台为 `linux/arm64`。镜像重新构建后 ID 和校验值会变化，应以对应的
`.sha256` 文件为准。

## 已完成验证

Mac 上的 ARM64 容器冒烟测试已经确认：

- ROS master 正常启动。
- `/laserMapping` 正常启动。
- `/foxglove_bridge` 和 `/foxglove_nodelet_manager` 正常启动。
- 容器内 TCP 8765 可连接。
- `rosbag` 与 `python-gnupg` 可导入。
- Foxglove 可执行文件没有缺失的动态库。
- Livox 消息 MD5 与驱动端一致：
  - `CustomMsg`: `e4d6829bdfe657cb6c21a746c86b21a6`
  - `CustomPoint`: `109a3cc548bb1f96626be89a5008bd6d`
- 不存在的 `BAG_FILE` 会输出明确错误并以非零状态退出。
- 入口脚本语法、Compose 配置及 zstd 归档完整性检查通过。

此前在板卡上的临时验证确认 FAST-LIVO 能处理约 2.4 GB 的测试 bag，
IMU 初始化、LIO/VIO 和 voxel map 更新正常，Foxglove Bridge 能监听 8765。
测试 bag 的输入话题为 `/livox/lidar`、`/camera/imu` 和
`/camera/color/image_fast_livo`。

## 传输与加载

板卡恢复在线后，从 Mac 传输算法镜像：

```bash
rsync -ahP \
  dist/daib-algorithm-openeuler-arm64.tar.zst \
  orangepi@192.168.218.200:/mnt/ssd/
```

在板卡上校验并加载：

```bash
cd /mnt/ssd
sha256sum daib-algorithm-openeuler-arm64.tar.zst
docker load -i daib-algorithm-openeuler-arm64.tar.zst
docker image inspect daib-algorithm:openeuler-arm64 \
  --format 'ID={{.Id}} ARCH={{.Architecture}} SIZE={{.Size}}'
```

Docker 可以直接加载 `.tar.zst`。已有的相同镜像层会在 Docker 存储中
复用，但离线归档仍是完整镜像，所以每次仍需传输整个文件。频繁更新时可
部署局域网 registry，让 `docker pull` 只传输板卡缺少的层。

## 局域网 Registry

2026-08-09 已在构建 Mac 上建立并验证 Docker Distribution Registry：

| 项目 | 当前值 |
|---|---|
| Orange Pi 当前管理地址 | `orangepi@192.168.218.200` |
| Mac 局域网地址 | `192.168.218.119` |
| Registry 地址 | `http://192.168.218.119:5050` |
| 容器 | `daib-registry` |
| 镜像 | `registry:2` |
| 持久化卷 | `daib-registry-data` |
| 重启策略 | `unless-stopped` |
| 当前仓库 | `daib-algorithm` |
| 当前标签 | `openeuler-arm64`、`yyy-openeuler-arm64` |
| YYY manifest digest | `sha256:42e1f92c9ff965660f489dac4c8fa0cd625bdb1653bc79b9cc167c5efdafc762` |

使用 `5050` 而不是默认的 `5000`，因为 macOS ControlCenter/AirPlay 已监听
`5000`。本机和局域网地址的 `/v2/` 均已返回 `{}`，镜像首次 push 成功，
catalog 与 tag API 也已验证。

Mac 推送命令：

```bash
docker tag \
  daib-algorithm:openeuler-arm64 \
  localhost:5050/daib-algorithm:openeuler-arm64
docker push localhost:5050/daib-algorithm:openeuler-arm64
```

板卡需要在已有 `/etc/docker/daemon.json` 中合并以下配置，保留已有的
`data-root` 等字段：

```json
{
  "insecure-registries": ["192.168.218.119:5050"]
}
```

板卡端预定操作：

```bash
sudo systemctl restart docker
curl http://192.168.218.119:5050/v2/
docker pull 192.168.218.119:5050/daib-algorithm:openeuler-arm64
```

`deploy/.env` 中应设置：

```dotenv
ALGORITHM_IMAGE=192.168.218.119:5050/daib-algorithm:openeuler-arm64
```

Registry 为可信局域网内的 HTTP 服务，不应暴露到公网。Mac 地址应通过
DHCP 保留保持稳定。2026-08-10 已从板卡增量拉取 `yyy-openeuler-arm64`，
仅重建算法服务，并确认容器为 `healthy`、`restart_count=0`。镜像中的
`mapping_mid70_d435i.launch` 使用 `/livox/lidar` 和 `/camera/imu`，修复了
纯 YYY 源码镜像缺少板端传感器 launch 导致的启动失败。

首次下载 `registry:2` 时，终端的 `https_proxy=localhost:7897` 不能单独
影响 Docker daemon。启用 macOS 系统 HTTP/HTTPS 代理
`127.0.0.1:7897` 后，Docker Desktop 才成功完成 pull。Docker daemon
显示的 `http.docker.internal:3128` 是 Docker Desktop 内部转发端点。

加载后使用已有镜像启动，不在板卡重新构建：

```bash
cd /mnt/ssd/daib
docker compose --env-file deploy/.env \
  -f deploy/compose.orange-pi-5-max.yml \
  up -d --no-build
```

确认新镜像和容器正常后，可删除 `/mnt/ssd` 下的传输归档。清理旧镜像前
先运行 `docker image ls --filter dangling=true` 检查目标，不要删除仍被
容器使用的镜像。

## 后续待办

1. 接入 Livox，确认 `enP3p49s0` 的实际 CIDR，再决定是否启用自动配网。
2. 接入 D435i，确认 USB 3.0 枚举、权限、图像和 IMU 数据。
3. 使用 `/mnt/ssd/bags` 中的测试 bag 回归 FAST-LIVO 和 Foxglove。
4. 使用 Foxglove 的 `camera_init` Fixed Frame 检查点云；暂不发布 `view`
   坐标变换。
5. 验证传感器时间同步、标定参数、散热和长时间运行稳定性。
