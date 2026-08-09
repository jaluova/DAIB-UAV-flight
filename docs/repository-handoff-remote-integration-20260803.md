# 当前仓库交接与远端对接说明

日期：2026-08-03

## 1. 结论

当前工程可以继续与远端协作，但还没有达到“同学克隆根仓库后直接复现”的状态。

Git历史层面的结论：

- 根仓库、FAST-LIVO2和EGO的远端分支都是本地分支的祖先，没有待合并的远端
  提交；
- PX4/XTDrone bundle与远端完全同步；
- DAIB-Explorer落后远端1个提交，而且本地修改与远端修改重叠；
- 本轮只执行了`git fetch`，没有执行`pull`或`push`。

本轮成功验证了所有远端的读取权限和网络连通性，但没有用`push --dry-run`测试写入
权限，也不知道共享仓库是否配置了分支保护。文中的“可快进推送”只表示提交图满足
Git快进条件，不代表当前账号一定有直接写入`main`的权限。

系统接口层面的结论：

- 当前可运行基线是恢复后的原始FAST-LIVO2接口；
- 远端DAIB路线仍以PVBSM和`/daib_slam/*`接口为中心；
- 两条路线不能在没有明确架构选择的情况下直接混合；
- 当前稳定仿真版本应作为独立分支提交，不建议直接覆盖共享`main`。

## 2. 仓库状态快照

本表中的远端引用已在2026-08-03重新执行`git fetch --prune origin`。

| 仓库 | 远端 | 本地HEAD | 相对远端 | 工作区 | 当前判断 |
|---|---|---|---:|---|---|
| 根仓库`cc-chat` | `jaluova/super-fastlivo2` | `b971551` | ahead 4 | 大量未跟踪文件 | Git可快进推送，但不能复现整个工程 |
| `DAIB-LIVO` | `YYY0702/DAIB-LIVO` | `9883f56` | ahead 6 | clean | Git可快进推送，语义上会撤掉PVBSM |
| `DAIB-Planner` | `YYY0702/DAIB-Planner` | `157f67a` | ahead 2 | 12个未暂存修改、4个已暂存修改、18个未跟踪文件 | 不能直接pull或一次性commit |
| PX4/XTDrone bundle | `HarveyZhang26/FAST-LIVO2_PX4-1.13_XTDrone_Gazebo` | `c912982` | 0/0 | clean | 与远端一致，但本项目仿真launch不在该仓库中 |
| `DAIB-Explorer` | `YYY0702/DAIB-Explorer` | `6524b89` | behind 1 | 2个本地修改 | 需先保存本地修改再处理远端提交 |

远端关键提交：

```text
super-fastlivo2 origin/master: 5104eae
DAIB-LIVO origin/main:      0ef8b92
ego-planner origin/main:        cf9784f
PX4 bundle origin/main:         c912982
DAIB-Explorer origin/main:      d08bd30
```

## 3. 当前可运行基线

当前验证使用恢复后的FAST-LIVO2稳定树：

```text
FAST-LIVO2 local HEAD: 9883f56
map_sliding_en: false
PVBSM runtime: removed
```

当前真实接口为：

```text
FAST-LIVO odom:  /aft_mapped_to_init
FAST-LIVO cloud: /cloud_registered
SLAM frame:      camera_init
PX4 odom:        /iris_0/mavros/local_position/odom
EGO pose output: /xtdrone/iris_0/cmd_pose_enu
```

当前仿真A/B链使用：

```text
odom_topic=/aft_mapped_to_init
cloud_topic=/cloud_registered
world_frame=camera_init
require_planning_input_valid=false
```

也可以通过`px4_odom_camera_init.py`把仿真起点对齐的PX4 odom仅做frame重标记后
交给EGO。该适配器不估计真实的`map -> camera_init`变换。

完整多终端命令见：

```text
docs/current-indoor3-livo-ego-multiterminal-20260803.md
```

## 4. FAST-LIVO2本地工作

本地相对远端的6个提交：

```text
ee1deac feat: publish lidar-corrected IMU-rate odometry
b4674be feat: add LIO-only XTDrone simulation launch
37fcb30 fix: use XTDrone camera calibration in simulation
538ef4f chore: enable simulated VIO by default
9eee7fd fix: restore stable FAST-LIVO2 simulation baseline
9883f56 merge: record PVBSM remote update without restoring it
```

当前保留的稳定性工作：

- 丢弃少于2个有效点的LiDAR/Livox帧；
- 清理无效队头，避免同一坏帧永久阻塞；
- 纯LIO每帧清理`meas.measures`，避免历史无界增长；
- 增加等待IMU的限频诊断；
- 保留`mapping_avia_sim.launch`；
- 支持LIVO/LIO选择、blind、图像时间偏移和XTDrone外参开关。

当前`9883f56`已经把远端`0ef8b92`作为第二父提交纳入历史，所以从Git角度
`origin/main`是本地`main`的祖先。直接push在Git协议上属于快进更新。

但是本地树相对远端删除或恢复了大量PVBSM、DAIB-CEM和视觉选择实现。直接推送
共享`main`会让远端同学看到“提交历史已合并，但功能被恢复版撤掉”。建议推送到：

```text
stable-xtdrone-sim-20260803
```

再通过PR说明这是稳定仿真分支，不是PVBSM远端路线的无冲突升级。

## 5. EGO本地工作

EGO已有两个本地提交：

```text
0a33e3c feat: plan with fresh IMU-rate odometry
157f67a fix: restore XTDrone pose output from trajectory server
```

工作区还包含尚未提交的实现：

- odom、点云和planning-valid失效后的安全锁存；
- 一次性急停轨迹与人工重启要求；
- `planning_cloud_px4_bridge`及其时间插值核心和测试；
- EGO活动轨迹显示和重规划连续性修正；
- traj server yaw rate限制；
- `daib_manual.launch`的PX4 map正式接口参数；
- 当前A/B使用的`obstacles_inflation=0.3`可配置参数；
- PX4 odom仿真起点适配脚本；
- Indoor3相关launch和RViz配置。

当前索引是混合状态：4个文件已暂存，12个文件只在工作区修改，另有18个未跟踪
文件。不能使用一次`git add . && git commit`作为共享提交，否则会把不同阶段、
历史对照和可能的Python缓存混在一起。

建议至少拆成以下提交：

```text
1. planning_cloud_px4_bridge + core tests
2. planning safety latch + watchdog tests
3. traj server yaw/trajectory continuity changes
4. manual and Indoor3 launch/configuration
5. documentation
```

EGO远端当前没有本地尚未包含的新提交，因此整理工作区之前不需要merge。但应先
创建功能分支，例如：

```text
indoor3-local-planning-safety-20260803
```

## 6. DAIB-Explorer远端风险

DAIB-Explorer远端新增：

```text
d08bd30 feat: retain PVBSM coverage after detail demotion
```

远端提交修改：

```text
README.md
config/explorer.yaml
docs/ARCHITECTURE.md
docs/RUNTIME_VALIDATION.md
include/daib_explorer/pvbsm_memory.h
src/explorer_node.cpp
src/pvbsm_memory.cpp
test/explorer_core_test.cpp
```

本地也修改了`README.md`和`config/explorer.yaml`，因此存在直接文本冲突风险。
更重要的是，该远端提交继续增强PVBSM，而当前FAST-LIVO2稳定树已经删除PVBSM
发布端。即使Git冲突解决，运行时也没有数据来源。

当前稳定仿真阶段不应启动DAIB-Explorer。需要继续Explorer路线时，应在独立分支
恢复并验证FAST-LIVO2的PVBSM接口，再合并`d08bd30`。

## 7. PX4、world和launch的归属

PX4/XTDrone bundle仓库本身与远端完全一致。当前容器中新增的文件并不在该Git
仓库的工作区中，而是单独保存在根工作区并部署到容器：

```text
scripts/indoor3_my.launch
simulation/indoor3_custom/indoor3_custom.world
simulation/indoor3_custom/indoor3_custom_my.launch
simulation/indoor4/indoor4_my.launch
```

容器部署路径：

```text
/root/PX4_Firmware/launch/indoor3_my.launch
/root/PX4_Firmware/launch/indoor3_custom_my.launch
/root/PX4_Firmware/launch/indoor4_my.launch
/root/PX4_Firmware/Tools/sitl_gazebo/worlds/indoor3_custom.world
```

这些文件目前在根仓库中仍是未跟踪状态。同学只克隆任何一个远端仓库都不会得到
它们。建议把`simulation/`作为根集成仓库的正式目录提交，并提供一个只负责复制
文件到PX4路径的部署脚本，不要直接修改第三方PX4 bundle的`main`。

## 8. 根仓库的复现问题

根仓库当前只跟踪17个文件，没有`.gitmodules`。以下目录虽然各自是Git仓库，
但从根仓库视角全部只是未跟踪目录：

```text
src/
├── DAIB-LIVO/
├── DAIB-Planner/
└── DAIB-Explorer/
FAST-LIVO2_PX4-1.13_XTDrone_Gazebo/
```

因此同学克隆`super-fastlivo2`后不会自动得到任何子仓库，也不知道应该固定在哪个
commit。容器里的已部署源码和二进制同样不是可共享的版本控制来源。

推荐二选一：

1. 使用Git submodule，固定四个子仓库的commit；
2. 增加`repos.yaml`，用`vcs import`克隆并固定各仓库版本。

在EGO工作区整理并提交之前，暂时不能生成准确的固定版本清单。

根仓库还应补充忽略规则，至少排除：

```text
__pycache__/
*.pyc
backups/
*.tar.gz
```

`daib_devel_v6.tar.gz`和运行备份不应进入普通Git历史；如确需共享，应使用Release
附件或专门的制品存储。

## 9. 接口兼容矩阵

| 消费方需求 | 当前稳定FAST-LIVO2 | 远端DAIB路线 | 结果 |
|---|---|---|---|
| SLAM odom | `/aft_mapped_to_init` | `/daib_slam/odom`或`imu_odom` | 话题不兼容 |
| EGO障碍点云 | `/cloud_registered` | `/daib_slam/planning_cloud_lidar`再经PX4 bridge | 话题和frame流程不兼容 |
| planning-valid | 无 | `/daib_px4/planning_input_valid` | A/B链必须关闭检查 |
| Explorer长期记忆 | 无PVBSM | `/daib_slam/pvbsm_delta` | 当前无法运行 |
| EGO控制输出 | XTDrone Pose | 正式目标为PositionCommand控制器 | 当前仍是历史仿真链 |

当前可以稳定开展的是FAST-LIVO2和EGO的仿真A/B测试，不应把该状态描述为完整DAIB
闭环或真正无GPS闭环。

## 10. 推荐协作流程

### 阶段A：冻结当前稳定仿真基线

1. FAST-LIVO2推送到独立稳定分支并发PR；
2. 将EGO工作区按功能拆分提交到独立分支；
3. 将`simulation/`、当前启动文档和部署脚本提交到根集成仓库；
4. 固定各子仓库commit；
5. 由第二台机器从零部署并执行多终端启动验收。

阶段A验收接口固定为：

```text
/aft_mapped_to_init
/cloud_registered
camera_init
```

### 阶段B：恢复正式PX4 map局部规划闭环

1. 在FAST-LIVO2独立分支恢复雷达体坐标规划点云；
2. 启用并测试EGO PX4点云时间插值桥；
3. EGO恢复`require_planning_input_valid=true`；
4. odom、点云、目标和轨迹统一为PX4`map`；
5. 通过超时、跳变和急停测试后再合并。

### 阶段C：再接DAIB-Explorer和无GPS

1. 明确是否保留PVBSM架构；
2. 若保留，恢复FAST-LIVO2发布端并合并Explorer远端提交；
3. 将FAST-LIVO2 odom注入PX4 EKF并禁止GPS融合；
4. 完成静止、起飞、悬停、往返和降落验收；
5. 最后恢复Explorer任务闭环。

## 11. 同学接手前不要执行的操作

在当前状态下不要直接执行：

```text
git pull                      # EGO和Explorer工作区不干净
git add .                     # 会混入子仓库、备份、pyc和大制品
git push origin main          # FAST-LIVO会语义上撤掉远端PVBSM
```

安全的只读检查命令：

```bash
git fetch --prune origin
git status --short --branch
git log --oneline --decorate --graph --all -20
git rev-list --left-right --count HEAD...@{upstream}
git diff --check
```

## 12. 已完成验证与待验证项

已完成：

- 五个仓库远端引用刷新；
- FAST-LIVO2 Release编译通过；
- FAST-LIVO2合并后工作区干净；
- PX4 Indoor3、Indoor4和自定义world launch可被ROS解析；
- EGO `daib_manual.launch` XML和参数展开检查通过；
- 当前外参与实际`iris_realsense_livox` SDF静态推导一致；
- 各仓库`git diff --check`通过。

尚未完成：

- EGO全部未提交修改的完整测试和提交拆分；
- 新机器从零克隆部署；
- LIVO相机投影和高速旋转动态验收；
- PX4 map点云桥的正式飞行验收；
- DAIB-Explorer与当前稳定FAST-LIVO2的接口恢复；
- 真正禁止GPS后的PX4 EKF闭环。

## 13. 建议同学首先确认的决策

开始合并前应明确回答：

```text
1. 当前目标是稳定XTDrone仿真，还是继续远端PVBSM/DAIB路线？
2. FAST-LIVO2稳定恢复版是否接受作为独立长期分支？
3. EGO正式控制是否继续使用XTDrone Pose，还是切换PositionCommand控制器？
4. 根仓库使用submodule还是repos.yaml管理多仓库？
```

这四项没有确定前，建议只共享稳定分支和文档，不合并到各仓库共享`main`。
