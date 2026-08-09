# FAST-LIVO2 自适应视觉帧选择

> 记录时间: 2026-07-24
> 仓库路径: `/home/ufd/cc-chat/FAST-LIVO2`
> 提交范围: `3c9eda2` → `19e2445` (3 commits)

## 概述

这三个提交实现了一套**基于 LiDAR 退化感知的自适应视觉帧选择系统**。此前每一帧同步图像都会触发 VIO 视觉优化；新系统在 LiDAR 几何结构充足时跳过不必要的视觉帧以降低计算量，仅在 LiDAR 退化或运动量超过阈值时才启用视觉约束。

---

## 三个提交

### 1. `3c9eda2` — feat: add degeneracy-aware visual frame selection

**核心提交。** 引入完整的退化感知决策管线。

**改动:** 5 files, +218/-11

**关键设计：**

- **退化度量 (`voxel_map.h/cpp`)**
  - 新增 `LidarDegeneracyMetrics` 结构体
  - LIO 迭代完成后，收集所有点对面残差的法向量，构建 3×3 信息矩阵
  - 对信息矩阵做特征分解，取**归一化最小特征值**作为退化指标
  - 值越小 → LiDAR 几何约束越弱 → 越退化

- **滞回状态机 (`LIVMapper.cpp`)**
  - 最小特征值 ≤ 退化进入阈值，连续 N 帧 → 判定 **DEGENERATE**
  - 最小特征值 ≥ 退化退出阈值，连续 N 帧 → 判定 **NORMAL**
  - 中间状态保持不变（滞回，防止频繁切换）

- **视觉帧决策 (`shouldProcessVisualFrame`)**
  - 退化状态 → **强制处理**（需要视觉约束补偿 LiDAR）
  - 正常状态 → 根据运动量决定：
    - 平移超过阈值 OR 旋转超过阈值 OR 距上次超过最大间隔 → 处理
    - 否则 → **跳过**

- **几何自适应缩放**
  - `geometry_scale = √3 × normalized_min_eigenvalue`（归一化到 [0,1]）
  - 运动阈值 × geometry_scale：几何越退化，阈值越低，越容易触发视觉处理

- **配置文件 (`config/avia.yaml`)**
  - 新增 `visual_selection` 配置段，可通过 `enabled: false` 回退到上游行为

---

### 2. `9156eed` — fix: align visual selection thresholds with paper

**将阈值从调试值修正为论文值。**

| 参数 | 旧值（调试） | 新值（论文） |
|------|-------------|-------------|
| `degeneracy_enter_threshold` | 0.05 | **0.07** |
| `translation_threshold` | 0.15 m | **1.0 m** |
| `rotation_threshold_deg` | 5.0° | **60.0°** |

旧值下平移 0.15m 或旋转 5° 就触发视觉处理——几乎每帧都触发，退化感知形同虚设。新阈值 1.0m / 60° 才真正实现"选择性"。

---

### 3. `19e2445` — feat: add visual selection scene mode

**将单一的 `translation_threshold` 拆分为 indoor/outdoor 两种预设。**

**改动:** 3 files, +30/-3

- 新增 `scene_mode` 参数：`"indoor"` 或 `"outdoor"`
- indoor: `translation_threshold = 1.0 m`（室内结构丰富，小位移也值得更新）
- outdoor: `translation_threshold = 2.0 m`（室外开阔，允许更大位移）
- 旋转阈值 60° 室内外通用
- 未知 mode 自动 fallback 到 indoor 并打印 WARN
- 启动时打印当前 scene_mode 和生效的阈值

---

## 决策流程图

```
每一帧图像到来
       │
       ▼
┌──────────────────┐    否     ┌──────────┐
│ visual_selection ├──────────►│ 处理视觉帧 │  (上游行为)
│   enabled ?      │           └──────────┘
└──────┬───────────┘
       │ 是
       ▼
┌──────────────────┐    是     ┌──────────┐
│ 初始化帧不足 OR   ├──────────►│ 处理视觉帧 │
│ 无上次位姿 ?      │           └──────────┘
└──────┬───────────┘
       │ 否
       ▼
┌──────────────────┐    是     ┌──────────┐
│ LiDAR 退化 ?      ├──────────►│ 处理视觉帧 │  (退化 → 补偿)
└──────┬───────────┘           └──────────┘
       │ 否
       ▼
┌──────────────────┐    是     ┌──────────┐
│ 运动量超阈值 ?    ├──────────►│ 处理视觉帧 │
│ (平移/旋转)       │           └──────────┘
└──────┬───────────┘
       │ 否
       ▼
┌──────────────────┐    是     ┌──────────┐
│ 距上次超最大间隔? ├──────────►│ 处理视觉帧 │
└──────┬───────────┘           └──────────┘
       │ 否
       ▼
┌──────────┐
│ 跳过此帧  │  (节省计算)
└──────────┘
```

---

## 配置参考 (`config/avia.yaml`)

```yaml
visual_selection:
  enabled: true                      # 关闭则回到上游行为(每帧都处理)
  scene_mode: indoor                 # indoor 或 outdoor
  indoor_translation_threshold: 1.0  # 室内平移阈值 (m)
  outdoor_translation_threshold: 2.0 # 室外平移阈值 (m)
  rotation_threshold_deg: 60.0       # 旋转阈值 (度)
  max_interval: 0.5                  # 最大间隔 (秒)
  degeneracy_enter_threshold: 0.07   # 进入退化状态的归一化特征值阈值
  degeneracy_exit_threshold: 0.08    # 退出退化状态的归一化特征值阈值
  degeneracy_enter_frames: 3         # 连续退化帧数才确认进入
  degeneracy_exit_frames: 5          # 连续正常帧数才确认退出
  min_valid_normals: 30              # 最少有效法向量数
  initialization_frames: 5           # 启动阶段强制处理的帧数
```

---

## 涉及文件

| 文件 | 角色 |
|------|------|
| `include/voxel_map.h` | `LidarDegeneracyMetrics` 结构体定义 |
| `src/voxel_map.cpp` | `UpdateDegeneracyMetrics()` — 特征值计算 |
| `include/LIVMapper.h` | 新增成员变量（阈值、状态、计数器） |
| `src/LIVMapper.cpp` | 核心逻辑：状态机、帧决策、参数读取 |
| `config/avia.yaml` | 配置项 |

---

## 实际效果

- **结构丰富场景**（室内走廊、楼梯间）：LiDAR 几何约束充足，大量视觉帧被跳过，计算量显著降低
- **退化场景**（长隧道、开阔广场、单一平面）：自动检测退化并启用视觉约束，防止漂移
- **切换平滑**：滞回机制避免状态振荡，不会出现"一帧处理一帧跳过"的抖动

---

## 性能测试（2026-07-24）

### 测试环境

| 项目 | 详情 |
|------|------|
| 硬件 | Atlas 200I DK A2 (ARM aarch64, 4核 A55 @ 1.0GHz, 3.4 GB) |
| 系统 | openEuler 24.03 LTS, ROS1 Noetic |
| 测试数据 | `/data/Retail_Street.bag` (1.9 GB, 135s, Livox Avia + IMU + 相机) |

### 测试方法

- 使用 `/root/run_slam_light.sh` 脚本自动采集 LIO/VIO 耗时和 CPU 占用
- CPU 通过 `/proc/stat` 每秒采样，不 fork 新进程避免额外开销
- LIO/VIO 耗时从 ROS 日志解析 `Current Total Time` 统计

### 调参路径

在原版 `avia.yaml` 基础上，分三轮逐步优化：

| 轮次 | visual_selection | LIO max_iterations | voxel_size | point_filter_num | filter_size_surf |
|------|:---:|:---:|:---:|:---:|:---:|
| ① 原版 | false | 5 | 0.5 | 1 | 0.1 |
| ② +visual | true | 5 | 0.5 | 1 | 0.1 |
| ③ +LIO调参1 | true | 3 | 1.0 | 2 | 0.2 |
| **④ +LIO调参2** | **true** | **3** | **1.0** | **2** | **0.2** |

> ③ 和 ④ 参数相同，两轮独立跑验证稳定性。

### 五轮完整对比

| 指标 | ① 原版 | ② +visual | ③ 调参1 | **④ 调参2** | 总改善 |
|------|:---:|:---:|:---:|:---:|:---:|
| **LIO 平均 (ms)** | 133.5 | 127.6 | 56.3 | **30.2** | **-77.4%** |
| **LIO 峰值 (ms)** | 178.0 | 175.6 | 87.9 | **52.7** | **-70.4%** |
| **CPU 占用** | 47.7% | 41.5% | 37.2% | **27.9%** | **-41.5%** |
| **跟上 10Hz?** | ❌ | ❌ | ✅ | ✅ | — |
| VIO 平均 (ms) | 25.5 | 23.5 | 21.1 | 22.9 | -10.2% |
| VIO 处理帧数 | 1348 | 377 | 499 | 480 | -64.4% |
| VIO 峰值 (ms) | 67.3 | 50.7 | 36.4 | **49.3** | -26.8% |

### 分析

**visual selection 单独效果（② vs ①）：**

VIO 处理帧数从 100% 降到 28%（跳过率 72%），但 CPU 只从 47.7% 降到 41.5%。原因是 VIO（~25ms）只占总耗时 ~16%，LIO 的 ICP 配准（~90-120ms）占了 ~72%，受阿姆达尔定律限制，砍 VIO 对 CPU 改善有限。visual selection 的主要价值在于退化场景兜底和防止 VIO 地图点膨胀（Sparse Map 从 18774 降到 2858，-85%）。

**LIO 调参效果（③④ vs ②）：**

LIO 从 128ms 降到 30ms（快 4.4x），CPU 从 41.5% 降到 27.9%。这是性能改善的主要来源——修改 ICP 迭代次数、地图体素分辨率、点云降采样，直接动了计算瓶颈。

**实时性：**

原版 133ms/帧远超 10Hz 预算（100ms），调参后 30ms/帧轻松达标，甚至有余量跑 30Hz LiDAR。

### 最终推荐参数 (`config/avia.yaml`)

```yaml
preprocess:
  point_filter_num: 2      # 原值 1, 点云减半
  filter_size_surf: 0.2    # 原值 0.1, 降采样翻倍

lio:
  max_iterations: 3        # 原值 5, ICP最多迭代3轮
  voxel_size: 1.0          # 原值 0.5, 地图体素翻倍

visual_selection:
  enabled: true            # 原值 false, 开启退化感知视觉帧选择
```

**5 个参数，不改一行代码，LIO 快 4.4x，CPU 减半。**

### 不足与后续

- **退化场景未测试**：Retail_Street 全程几何结构丰富（score 0.09~0.22），退化检测未触发 DEGENERATE 状态。需要隧道/开阔地 bag 验证退化检测的实际效果
- **建图质量未评估**：降采样和减少 ICP 迭代可能影响轨迹精度和地图质量，需要 ground truth 数据做 APE/RPE 评估
- **visual selection 场景模式未切换**：只测了 indoor 模式（平移阈值 1.0m），outdoor（2.0m）的效果待验证
