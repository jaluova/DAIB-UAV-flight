# Atlas 200I DK A2 开发板信息

## 网络
- 本机 IP: 192.168.0.101
- 开发板 IP: 192.168.0.2
- 默认 SSH 用户: root

## 硬件

| 项目 | 详情 |
|------|------|
| 型号 | Atlas 200I DK A2 |
| CPU | ARM aarch64, 4 核 |
| 内存 | 3.4 GiB |
| Swap | 8 GiB |
| 磁盘 | 57G (已用 23G, 可用 32G) |
| NPU | Ascend 310B4, 功耗 7.7W, 显存 1264/3513 MB |

## 软件

| 项目 | 详情 |
|------|------|
| 操作系统 | openEuler 22.03 LTS |
| 内核 | 5.10.0+ (aarch64) |
| Docker | 18.09.0 (overlay2) |
| NPU 驱动 | npu-smi 23.0.rc3 |

## Docker

### 容器
- `ros1_dev` (bf6d2d5c9a3b)
  - 镜像: `openeuler/openeuler:24.03-lts-sp4` (ROS1 Noetic, FAST-LIVO2 源码编译)
  - 代理: `http://192.168.0.101:7897`
  - 挂载: `/data` → `/data`, `/dev/bus/usb` → `/dev/bus/usb`
- `ros2_dev` (d7e3be65a583)
  - 镜像: `fastlivo2-arm64:v3` (ROS2 Humble)
  - 代理: `http://192.168.0.101:7897`
  - 挂载: `/data` → `/data`, `/dev/bus/usb` → `/dev/bus/usb`

### 镜像
- `fastlivo2-arm64:v3` — 21.8 GB (FastLIVO2 SLAM + ROS2, ARM64)
- `openeuler/openeuler:22.03-lts-sp4` — 203 MB

## 常用命令
- SSH 登录: `ssh root@192.168.0.2`
- NPU 状态: `npu-smi info`
- 容器操作: `ssh root@192.168.0.2 "docker start ros2_dev"`
