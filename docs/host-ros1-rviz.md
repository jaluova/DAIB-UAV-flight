# 主机 ROS1 rviz 可视化 (NVIDIA GPU 加速)

## 目的

在主机 (Ubuntu 22.04, ROS2) 上运行 ROS1 rviz，通过 Docker + NVIDIA GPU 加速，
可视化 Atlas 200I DK A2 开发板上的 FAST-LIVO2 SLAM 建图结果。

## 拓扑

```
本机 (192.168.0.101)               Atlas 200I DK A2 (192.168.0.2)
┌─────────────────────────┐        ┌─────────────────────────┐
│ ros1-rviz 容器           │  TCP   │ ros1_dev 容器            │
│ (ROS1 Noetic, NVIDIA)   │◄──────►│ roscore + fast_livo     │
│                         │        │                         │
│ - rviz 显示              │        │ - /tf                    │
│ - ROS_MASTER_URI → 开发板│        │ - /cloud_registered      │
└─────────────────────────┘        │ - /Laser_map             │
                                   │ - /path                  │
                                   └─────────────────────────┘
```

## 镜像：ros1-rviz:latest

### 构建过程

1. 拉取基础镜像
   ```bash
   docker pull ros:noetic-ros-core
   ```

2. 安装 rviz 和工具
   ```bash
   # 换国内源加速
   sed -i 's|archive.ubuntu.com|mirrors.ustc.edu.cn|g' /etc/apt/sources.list
   sed -i 's|packages.ros.org|mirrors.ustc.edu.cn/ros|g' /etc/apt/sources.list.d/ros1-latest.list
   apt update && apt install -y ros-noetic-rviz mesa-utils
   ```

3. 创建自定义镜像
   ```bash
   docker commit <容器ID> ros1-rviz:latest
   ```

### NVIDIA GPU 加速

主机需安装 nvidia-container-toolkit：

```bash
# 加 repo（需走代理）
curl -x http://127.0.0.1:7897 -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -x http://127.0.0.1:7897 -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sed 's|\$(ARCH)|amd64|g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# 安装
sudo apt -o Acquire::https::Proxy="http://127.0.0.1:7897" update
sudo apt -o Acquire::https::Proxy="http://127.0.0.1:7897" install -y nvidia-container-toolkit

# 配置 Docker runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

容器内需设置 LD_PRELOAD 指向 NVIDIA GLX 库（即使 `--gpus all` 已传递设备）：

```bash
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0
```

验证：
```bash
glxinfo | grep "OpenGL renderer"
# → NVIDIA GeForce RTX 4060 Laptop GPU/PCIe/SSE2
```

## 启动

### 前置条件

1. 开发板上 roscore 已运行
2. 开发板上 fast_livo 已启动（`roslaunch fast_livo mapping_avia.launch`）
3. bag 正在播放或已播放完成（查看建图结果）

### 启动容器

```bash
docker run -it --net=host \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v $HOME/.Xauthority:/root/.Xauthority:ro \
  -e XAUTHORITY=/root/.Xauthority \
  --gpus all \
  -e ROS_MASTER_URI=http://192.168.0.2:11311 \
  -v /tmp/fast_livo2.rviz:/root/fast_livo2.rviz \
  ros1-rviz:latest bash
```

### X11 授权

启动容器前，主机上需允许 Docker 连接 X11：

```bash
xhost +local:docker
```

### 容器内初始化

```bash
# 必须：设置 hosts 使容器能解析开发板 hostname（ROS1 数据传输依赖 hostname）
echo "192.168.0.2 davinci-mini" >> /etc/hosts

# NVIDIA GLX preload
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0

# 启动 rviz
rviz -d /root/fast_livo2.rviz
```

## rviz 配置

### 关键话题

| 话题 | 类型 | 说明 |
|------|------|------|
| `/tf` | TF | 坐标系变换 (camera_init → aft_mapped) |
| `/cloud_registered` | PointCloud2 | 当前帧点云（数据量小） |
| `/Laser_map` | PointCloud2 | 全局累积地图（数据量大，可能卡） |
| `/path` | Path | SLAM 轨迹 |

### Fixed Frame

设为 `camera_init`

### 性能优化

- `/Laser_map` 的 Decay Time 设为 1（不无限累积显示）
- Point Size 改小（1-2 px）
- Style 用 Flat Squares 而非 Spheres
- 如果网络带宽不够，优先保留 `/cloud_registered` + `/path`

### rviz 配置文件

从开发板 `ros1_dev` 容器获取：

```bash
ssh root@192.168.0.2 "docker cp ros1_dev:/root/catkin_ws/src/FAST-LIVO2/rviz_cfg/fast_livo2.rviz /tmp/"
scp root@192.168.0.2:/tmp/fast_livo2.rviz /tmp/
```

路径：`/tmp/fast_livo2.rviz`

## 故障排查

### 话题能列出但无数据

ROS1 多发机通信经典问题：
- 话题列表通过 master (HTTP) 分发，始终可达
- 数据传输靠发布者直连订阅者 (TCP)，依赖 hostname 解析

解决：`echo "192.168.0.2 davinci-mini" >> /etc/hosts`

### rviz 显示卡顿

1. 确认 GPU 渲染：`glxinfo | grep "OpenGL renderer"` → NVIDIA（非 llvmpipe）
2. 检查点云带宽：`rostopic bw /Laser_map`
3. 优先使用 `/cloud_registered`（单帧）而非 `/Laser_map`（全局地图）

### llvmpipe 而非 NVIDIA

即使 `--gpus all` + nvidia-container-toolkit 正确配置，容器内仍需：
```bash
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0
```

### 代理

- 主机 Docker daemon 代理：`/etc/systemd/system/docker.service.d/http-proxy.conf`
- 容器内 apt 代理：`export http_proxy=http://127.0.0.1:7897`
- 国内源直连时记得 `unset http_proxy https_proxy`

## 关联文档

- [atlas-board-info.md](atlas-board-info.md) — 开发板硬件 & Docker 容器
- [dds-communication.md](dds-communication.md) — ROS2 FastDDS 通信配置（仅 ROS2，本方案不涉及）
