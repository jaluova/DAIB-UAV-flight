# 2026-08-03 工作总结与远端差异

## 1. 今日结论

今天的工作最终聚焦于Indoor3中的FAST-LIVO2稳定性，没有继续扩大EGO、障碍膨胀或
控制器改造范围。

主要结论如下：

1. FAST-LIVO2已恢复到项目最初使用的原始算法基线，移除了本地DAIB-LIO、视觉帧
   选择、PVBSM、视觉长期记忆和`/daib_slam/*`扩展接口。
2. 纯LIO的“运行一段时间后永久断更”不是节点崩溃。根因是单点LiDAR帧进入同步
   队列后，旧代码只返回等待，却不弹出无效队首，后续正常帧永远无法处理。
3. 纯LIO队首阻塞已修复；小于2点的帧会被拒绝，遗留无效队首会被清理，历史测量
   队列不再无界增长，并增加了明确的IMU等待日志。
4. `blind=0.2 m`会保留约0.22至0.28米的机体自反射点。EGO再膨胀0.3米后会认为
   飞机位于障碍物中。仿真当前使用`blind=0.4 m`更合适。
5. XTDrone模型与原真机Avia外参不同。模型几何给出的LiDAR到IMU外参为
   `T=[-0.05, 0, -0.205]`、`R=I`。修正后，靠墙旋转时LIO误判向上运动的问题
   明显改善。
6. LIVO还需要使用XTDrone的LiDAR到左相机光学系外参：
   `Pcl=[0.06, -0.095, -0.05]`以及标准光学轴旋转。第一轮图像时间偏移使用
   `0.0 s`，不再直接沿用未经当前Gazebo插件验证的`0.1 s`。

## 2. FAST-LIVO2实际改动

仓库：`DAIB-LIVO`

今日新增提交：

```text
9eee7fd fix: restore stable FAST-LIVO2 simulation baseline
```

该提交包括：

- 恢复原始FAST-LIVO2核心LIO/VIO和voxel map实现；
- 删除与当前稳定性验证无关的DAIB/PVBSM扩展代码、测试和接口文档；
- 保留手动多终端使用的`mapping_avia_sim.launch`；
- 支持通过launch参数选择LIO/LIVO、图像时间偏移和LiDAR盲区；
- 增加XTDrone LiDAR-IMU与LiDAR-Camera外参的独立可选开关；
- 修复纯LIO单点帧永久阻塞和测量历史无界增长；
- 对无效LiDAR帧和IMU同步等待增加限频诊断日志；
- 忽略运行产生的`Log/*`和备份配置，不把测试产物提交到Git。

当前LIVO测试命令：

```bash
roslaunch fast_livo mapping_avia_sim.launch \
  rviz:=false \
  img_en:=1 \
  blind:=0.4 \
  img_time_offset:=0.0 \
  use_xtdrone_lidar_imu_extrinsic:=true \
  use_xtdrone_camera_extrinsic:=true
```

验证情况：

- `mapping_avia_sim.launch`通过XML检查；
- launch参数展开结果已核对；
- 容器`/root/daib_fastlivo_ws`完成Release编译；
- 新的纯LIO保护逻辑已进入最终二进制；
- 用户实测确认纯LIO断更问题修复；
- 用户实测确认XTDrone LiDAR-IMU外参改善靠墙旋转时的高度误判；
- 修正相机外参后的完整LIVO飞行仍待最终A/B验收。

## 3. 与远端分支的差异

远端引用已在2026-08-03刷新。以下数量以本文档编写时为准。

| 仓库 | 本地分支相对远端 | 工作区 | 说明 |
|---|---:|---|---|
| 根仓库`cc-chat` | ahead 3 | 大量未跟踪资料 | 已有三项本地部署/接口文档提交；本文档提交后将再ahead 1 |
| `DAIB-LIVO` | ahead 5, behind 1 | clean | 本地恢复稳定原版并增加仿真修复；远端继续发展PVBSM |
| `DAIB-Planner` | ahead 2 | dirty | 有规划桥、安全锁存和launch等未提交工作，本次未纳入 |
| `DAIB-Explorer` | behind 1 | dirty | 本地只有术语/配置注释修改；远端新增PVBSM覆盖保持 |
| `FAST-LIVO2_PX4-1.13_XTDrone_Gazebo` | 同步 | clean | 作为原始参考快照，不做修改 |

### 根仓库本地已有提交

```text
f009cf1 docs: summarize indoor3 px4 odom slam integration
f47cbb9 chore: add local DAIB simulation environment
093a52e docs: define IMU cloud planning deployment contract
```

相对`origin/master`合计增加4个受控文件、1157行，主要是Indoor3集成记录、IMU点云
规划接口契约、容器环境脚本和合约测试。

### FAST-LIVO2本地独有提交

```text
9eee7fd fix: restore stable FAST-LIVO2 simulation baseline
538ef4f chore: enable simulated VIO by default
37fcb30 fix: use XTDrone camera calibration in simulation
b4674be feat: add LIO-only XTDrone simulation launch
ee1deac feat: publish lidar-corrected IMU-rate odometry
```

其中早期四个提交建立了XTDrone仿真入口和DAIB接口；`9eee7fd`根据今天的实测决定
撤回不稳定扩展，以原始FAST-LIVO2为主线，仅保留经过定位的问题修复和仿真参数化。

FAST-LIVO2远端独有提交：

```text
0ef8b92 feat: preserve PVBSM memory across map sliding
```

该远端提交继续增强PVBSM，而本地当前明确移除了PVBSM。后续不能直接把它当作普通
落后提交合并，必须先决定是否重新引入PVBSM架构。

### EGO本地独有提交与未提交工作

已提交但尚未推到远端：

```text
157f67a fix: restore XTDrone pose output from trajectory server
0a33e3c feat: plan with fresh IMU-rate odometry
```

工作区还存在PX4时间插值点云桥、EGO输入失效锁存、控制/launch适配和测试等改动。
由于今天后半段明确冻结EGO工作，这些文件没有被本次提交，也没有替用户清理或回退。

### Explorer远端差异

本地落后远端：

```text
d08bd30 feat: retain PVBSM coverage after detail demotion
```

本地`README.md`和`config/explorer.yaml`仍有未提交的adapter到bridge术语调整。由于
FAST-LIVO2本地已经暂时移除PVBSM，Explorer更新需要等SLAM架构方向确定后再处理。

## 4. 其他今日工作

- 恢复`/root/fast_livo2.rviz`的原始FAST-LIVO2显示，并使用`RGB8`显示累计彩色点云；
- 创建并验证`/root/PX4_Firmware/launch/indoor1_my.launch`，但当前测试仍回到Indoor3；
- 保持PX4、XTDrone communication、FAST-LIVO2、适配器、EGO和RViz分终端启动；
- 明确键盘节点和EGO不能同时持续向XTDrone communication发送控制命令；
- 保留原始`/aft_mapped_to_init`和`/cloud_registered`作为恢复后FAST-LIVO2接口；
- 容器内部署文件已同步到`/root/daib_fastlivo_ws/src/fast_livo`。

## 5. 未纳入本次提交

以下内容有意保留在各自工作区，没有混入今天的SLAM提交：

- EGO点云桥、安全锁存、yaw rate和控制链实验代码；
- DAIB-Explorer本地术语修改；
- 根仓库中的历史调试文档、脚本、备份目录和压缩包；
- FAST-LIVO2运行日志、参数副本和bag；
- 容器外PX4工作区的`indoor1_my.launch`。

## 6. 下一步验收

1. 使用修正后的两组XTDrone外参和`img_time_offset=0.0`完成LIVO悬停、慢速旋转、
   快速旋转和近墙旋转测试。
2. 对照PX4 local odom记录FAST-LIVO2的Z轴误差、yaw误差、空帧比例和更新时间。
3. 只有在时间戳实测支持时才测试`img_time_offset=0.1`，每轮只改变一个参数。
4. LIVO稳定后再决定是否恢复EGO局部闭环和PVBSM/Explorer工作，不同时调整三个系统。
