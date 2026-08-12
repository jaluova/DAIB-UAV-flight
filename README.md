# DAIB 无人机自主系统

本仓库集成 DAIB 无人机的定位建图、自主探索、轨迹规划和 ARM64 实机部署能力。
当前运行环境以 ROS Noetic 为基础，目标设备为 Orange Pi 5 Max（RK3588），传感器
包括 Livox MID-70 和 Intel RealSense D435i。

> **当前运行基线（2026-08-12）**：所有实机测试和调试以 `sync_yyy` 主线为准。
> 旧 gpsless 分支、镜像、脚本和本地未提交修改不再作为当前启动依据。准确提交、
> 镜像 ID 和有效 launch 参数见
> [当前唯一运行基线](docs/CURRENT_SYNC_YYY_BASELINE.md)。

## 系统链路

```text
Livox MID-70 / D435i / IMU
            |
            v
       DAIB-LIVO
       定位与建图
            |
            | odom / planning cloud / degeneracy / PVBSM delta
            v
     DAIB-Explorer
   占据地图与探索目标
            |
            | goal / ready / occupied cloud
            v
      DAIB-Planner
  碰撞检查与 B-spline 轨迹
            |
            v
      Controller / PX4
```

上图是目标系统链路，不是默认容器启动后的现状。当前默认实机入口只启动独立 LIO；
Explorer 所需的退化度量和 PVBSM 等接口与当前稳定 LIVO 前端仍有差异，详见
[本地变更与算法影响审计](docs/local-change-audit-20260809.md)。

三个算法模块通过 ROS1 消息通信，不直接依赖彼此的源码头文件。定位链路保持高频
运行，探索和规划模块可以独立启动、停止或替换。

## 获取源码

三个算法模块以 Git 子模块管理。首次克隆时一并拉取子模块：

```bash
git clone --recurse-submodules https://github.com/jaluova/DAIB-UAV.git
```

已克隆主仓库时，可以补充初始化子模块：

```bash
git submodule update --init --recursive
```

## 核心模块

| 模块 | ROS 包 | 职责 |
|---|---|---|
| [DAIB-LIVO](src/DAIB-LIVO/) | `fast_livo` | LiDAR-Inertial-Visual 定位建图、退化检测和规划点云输出 |
| [DAIB-Explorer](src/DAIB-Explorer/) | `daib_explorer` | 占据地图、增量 frontier、探索记忆和目标选择 |
| [DAIB-Planner](src/DAIB-Planner/) | `ego_planner`、`daib_ego_bridge` 等 | 目标校验、局部碰撞地图、B-spline 生成和重规划 |

## 项目结构

```text
.
├── src/
│   ├── DAIB-LIVO/          定位与建图
│   ├── DAIB-Explorer/      自主探索
│   └── DAIB-Planner/       轨迹规划、集成桥和仿真依赖
├── deploy/
│   ├── Dockerfile.algorithm
│   ├── Dockerfile.drivers
│   ├── compose.orange-pi-5-max.yml
│   ├── scripts/            镜像构建、打包和容器入口脚本
│   ├── ros/                驱动容器所需的 ROS 兼容包
│   └── cmake/              构建兼容配置
├── scripts/                Orange Pi 实机启动、验收和录包脚本
├── patches/                第三方依赖的编译、时间戳和控制器补丁
├── docs/                   架构、硬件、标定、部署和调试记录
└── dist/                   生成的镜像归档及校验文件
```

`src/` 只存放算法源码。`deploy/` 负责构建和运行环境，`patches/` 中的文件在构建
第三方依赖时按需应用。`dist/` 是生成物目录，不应作为源码维护。

更完整的目录边界见 [项目结构说明](docs/PROJECT_STRUCTURE.md)。

## ARM64 镜像

构建环境需要 Docker、Buildx，以及可用的 `linux/arm64` builder。构建完整的算法
和驱动镜像：

```bash
BUILD_JOBS=1 ./deploy/scripts/build-openeuler-arm64-images.sh
```

只重新构建算法镜像：

```bash
BUILD_JOBS=1 ./deploy/scripts/build-algorithm-image.sh
```

构建结果写入 `dist/`。镜像基于 openEuler 24.03 LTS，算法容器包含 ROS Master、
三个 DAIB 算法模块和 Foxglove Bridge；驱动容器包含 RealSense 与 Livox 驱动。

详细依赖、代理配置和镜像传输流程见 [部署说明](deploy/README.md)。

## Orange Pi 部署

在目标设备上准备运行配置并启动容器：

```bash
cp deploy/.env.example deploy/.env
docker compose --env-file deploy/.env \
  -f deploy/compose.orange-pi-5-max.yml up -d --no-build
```

接好 D435i 和 MID-70 后，推荐用宿主机脚本启动并验收，而不是只检查容器状态：

```bash
./scripts/start_mid70_d435i_drivers.sh
```

验收通过后可以录制 FAST-LIVO 的三个实机输入话题：

```bash
./scripts/record_fast_livo_inputs.sh
```

查看运行状态：

```bash
docker compose --env-file deploy/.env \
  -f deploy/compose.orange-pi-5-max.yml ps

docker compose --env-file deploy/.env \
  -f deploy/compose.orange-pi-5-max.yml logs -f
```

默认情况下，算法容器只启动 DAIB-LIVO 的 LIO 模式。完成传感器外参、时间戳和话题
频率验证后，再启用相机 VIO、DAIB-Explorer、DAIB-Planner 和飞控链路。

## 相关文档

- [当前唯一运行基线：sync_yyy](docs/CURRENT_SYNC_YYY_BASELINE.md)
- [sync_yyy SLAM、Explorer、Planner 分层调试指南](docs/sync-yyy-pipeline-debug-guide-20260812.md)
- [本地变更与算法影响审计](docs/local-change-audit-20260809.md)
- [工程适配与算法边界说明](docs/collaboration-compatibility-handoff-20260809.md)
- [系统目录与上传边界](docs/PROJECT_STRUCTURE.md)
- [DAIB-Explorer 架构](src/DAIB-Explorer/docs/ARCHITECTURE.md)
- [DAIB-Planner 集成接口](src/DAIB-Planner/docs/DAIB_INTEGRATION.md)
- [Orange Pi 容器部署](deploy/README.md)
- [完整 PX4 数据链路](docs/px4-full-pipeline.md)
- [MID-70 与 D435i 外参标定](docs/mid70-d435i-manual-extrinsic-calibration.md)

## 安全边界

DAIB-Explorer 发布的是任务级探索目标，不是可直接发送给 PX4 的飞行指令。
目标必须经过 DAIB-Planner 的碰撞检查和轨迹生成，再由具备解锁状态机、指令超时
和急停能力的控制器执行。实机启用自主飞行前，应分别完成定位、探索、规划和控制
链路验证。
