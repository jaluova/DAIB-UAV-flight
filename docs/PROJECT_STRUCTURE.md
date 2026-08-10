# 项目目录与上传边界

更新日期：2026-08-10

## 当前目标

在 Apple Silicon Mac 上构建 `linux/arm64` 算法和驱动镜像，再部署到香橙派。
容器基线为 openEuler 24.03 LTS + ROS Noetic，目标设备为 Orange Pi 5 Max
（RK3588，ARM64），宿主系统为 Orange Pi Ubuntu 22.04.4 LTS。容器使用
Ubuntu 宿主机的 Rockchip 内核和独立的 openEuler 24.03 用户态。既有
Atlas/openEuler 记录只作为构建与排错依据，不是 Orange Pi 5 Max 的直接配置。

## 目录职责

```text
cc-chat/
├── deploy/                 ARM64 Dockerfile、Compose、入口和打包脚本
├── docs/                   架构、编译、标定、实机调试和历史经验
│   └── memory/             经验索引及历史存储配置
├── src/                    算法源代码
│   ├── DAIB-LIVO/          FAST-LIVO2 算法及 MID-70/D435i 配置
│   ├── DAIB-Planner/       EGO-Planner 和 DAIB 规划桥
│   └── DAIB-Explorer/      探索算法
├── FAST-Calib/             标定工具，不属于运行镜像
├── patches/                Livox 时间戳和控制器补丁
├── scripts/                Orange Pi 实机启动、验收和录包脚本
├── simulation/             Gazebo 场景，不进入实机部署包
├── FAST-LIVO2_PX4-1.13_XTDrone_Gazebo/
│                           上游仿真参考快照，不进入实机部署包
├── bags/                   大体积 rosbag，只在本地保存
├── backups/                恢复归档，只在本地保存
├── logs/                   运行日志，不上传
└── dist/                   生成的源码包和镜像包
```

## 上传到 Mac 的内容

`deploy/scripts/package-build-context.sh` 生成的源码包包含：

- `deploy/`
- `docs/`、`README.md`，以及存在时的 `CLAUDE.md`
- `src/DAIB-LIVO/`
- `src/DAIB-Planner/`
- `src/DAIB-Explorer/`
- `patches/`
- `scripts/`

源码包保留当前未提交实现和实机配置，但不包含任何嵌套 `.git` 历史。

## 不进入上传包

- `bags/`、`backups/`、`logs/`、`dist/`
- `FAST-Calib/`：需要重新标定时单独传输
- `simulation/` 和完整 PX4/XTDrone 仿真参考仓库
- `build/`、`devel/`、缓存、编辑器配置、图片和论文附件
- `daib_devel_v6.tar.gz`：旧 ARM64 动态链接编译产物

## 容器边界

算法容器运行 ROS Master、FAST-LIVO2、EGO-Planner 和 DAIB-Explorer。驱动容器
运行 librealsense/realsense2_camera 与 livox_ros_driver。两个容器使用 host 网络和
同一个 ROS Master；驱动容器需要访问 USB、V4L2、hidraw 和 LiDAR 实际网卡。

实机默认只启动 FAST-LIVO2 的 LIO 模式。确认外参、话题频率和时间戳后，再启用
相机 VIO、规划和飞行控制。
