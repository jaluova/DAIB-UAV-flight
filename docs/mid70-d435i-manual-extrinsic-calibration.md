# MID-70 + D435i 手动外参调整记录

更新日期：2026-08-06

本文记录 MID-70 到 D435i Color Optical 坐标系外参的手动投影检查、候选参数
迭代和 FAST-LIVO2 A/B 测试流程。原始联合标定配置始终保留，手调结果通过独立
候选 YAML 加载。

## 1. 当前诊断结论

- MID-70 + D435i 的 LIO-only 测试稳定，剧烈旋转和平移均不漂移。
- 完整 LIVO 偶发漂移，`/rgb_img` 中仍可能存在视觉候选点。
- `vio_state_update:=false` 时保留图像同步和 LIVO 扫描切片，但禁止视觉 EKF 修改
  位姿，实测不再漂移。
- 当前主问题锁定在视觉更新链路，LiDAR-Camera 空间外参是首要检查项；时间偏移、
  滚动快门和视觉异常更新门控仍需在空间外参稳定后继续检查。
- 原始传感器频率约为 LiDAR 10 Hz、图像 30 Hz、IMU 200 Hz。30 秒检查中
  LiDAR-Image 最近邻绝对时间差 P95 约 16 ms。

## 2. 坐标与参数约定

LiDAR 到彩色相机的变换为：

```text
p_camera = Rcl * p_lidar + Pcl
```

D435i Color Optical 坐标系：

```text
x：图像向右
y：图像向下
z：相机正前方
```

- `Rcl/Pcl`：LiDAR 到 D435i Color Optical，用于点云投影和视觉更新。
- `extrinsic_R/T`：LiDAR 到 D435i IMU Optical，供 FAST-LIVO2 的 LiDAR/IMU
  状态使用。
- 手调工具按 `S` 时会同时打印两组一致的参数，不要只修改其中一组。
- MID-70 向下倾斜和倒梯形扫描图案本身不需要被“调水平”；只检查真实物体的
  三维边缘是否投影到图像边缘。

## 3. 相关文件

宿主机工作区：

```text
/home/ufd/cc-chat/src/DAIB-LIVO
```

容器工作区：

```text
/root/daib_fastlivo_ws/src/fast_livo
```

配置与工具：

```text
config/mid70_d435i.yaml
    原始 FAST-Calib 联合标定基线，不覆盖。

config/mid70_d435i_manual_candidate.yaml
    当前手调工作候选，后续迭代覆盖这个文件。

config/mid70_d435i_manual_backup_v3_20260806.yaml
    第三组候选的固定备份。

launch/check_mid70_d435i_projection.launch
    独立原始点云到图像投影，不经过 FAST-LIVO2/VIO。

launch/mapping_mid70_d435i.launch
    实机 LIO/LIVO 启动文件。
```

## 4. 进入运行环境

不要输入带中文顿号的 `bash、`。从宿主机进入容器后加载正确工作空间：

```bash
docker exec -it ros1-rviz bash
source /opt/ros/noetic/setup.bash
source /root/daib_fastlivo_ws/devel/setup.bash
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=127.0.0.1
```

如果没有 source `/root/daib_fastlivo_ws/devel/setup.bash`，`roslaunch` 会报告找不到
`fast_livo` 包或 launch 文件。

## 5. 启动独立投影手调

先停止正在运行的 FAST-LIVO2，再执行：

```bash
roslaunch fast_livo check_mid70_d435i_projection.launch \
  view:=false \
  interactive:=true \
  manual_extrinsics:=true \
  time_window_ms:=0.0 \
  accumulate_scans:=10
```

`manual_extrinsics:=true` 表示先加载原始基线，再使用
`mid70_d435i_manual_candidate.yaml` 覆盖外参。因此窗口打开时六个滑条的中心位置
就是当前工作候选。

快捷键：

```text
S：打印叠加调整后的完整 Rcl/Pcl 和 extrinsic_R/T
R：恢复到当前投影进程启动时加载的候选基准
```

更新候选 YAML 后必须重启投影节点。运行中的 `R` 不会重新读取磁盘文件。

## 6. 滑条含义

旋转滑条中心为 `500`，每格 `0.01 deg`，范围约为 `+-5 deg`。平移滑条中心为
`200`，每格 `0.5 mm`，范围约为 `+-100 mm`。

| 滑条 | 正方向的主要图像效果 |
|---|---|
| `rx` | 投影向上 |
| `ry` | 投影向右 |
| `rz` | 投影顺时针旋转 |
| `tx` | 投影向右，距离越近越明显 |
| `ty` | 投影向下，距离越近越明显 |
| `tz` | 投影向主点收缩；负方向向外扩张 |

例如 `rx=480` 表示相对当前候选增加 `-0.20 deg`。界面中的 `dRPY/dT` 和按
`S` 打印的 `delta_*` 都是相对当前候选的增量，不是相对最初联合标定的累计量。

## 7. 推荐调节流程

### 7.1 旋转

1. 设备与目标全程静止。移动目标后等待至少 1 秒，让累计的 10 帧扫描全部刷新。
2. 使用 `2-3 m` 处的门框、大板外框或其他明显深度边缘。
3. `tx/ty/tz` 保持中心，只调整 `rx/ry/rz`。
4. 每次调整约 `0.1-0.2 deg`，观察多个水平、竖直边缘，而不是扫描花瓣形状。
5. 如果只在远处对齐、近处不对齐，先保留旋转，进入平移步骤。

### 7.2 平移

1. 将目标放到 `0.7-1.0 m`。
2. 保持已确定的旋转，只调整 `tx/ty/tz`。
3. 每次调整约 `1-2 mm`，单轮新增平移尽量不超过 `+-10 mm`。
4. `tz` 仅用于“中心基本对齐、越靠近图像边缘误差越大”的径向现象。
5. 再回到远距离复查；远处明显被破坏时，说明存在旋转和平移补偿。

### 7.3 多位置验证

同一组参数必须在以下情况同时成立：

- 近距离和远距离；
- 画面左、中、右；
- 画面上方和下方；
- 板外框、圆孔边缘、门框或桌沿等不同深度边缘。

不要根据 LIVO 漂移方向决定滑条方向。漂移是 EKF 累积结果，不能直接反推出某个
外参轴的正负误差。

## 8. 投影画面的判断标准

自适应颜色通常表示：

```text
红色：近处表面
绿色：中间深度
蓝色：远处背景
```

对带圆孔的标定板：

- 红色近处点应落在实体板面，并在真实孔边和板外框处终止。
- 蓝色远处点应主要出现在孔内和板外背景。
- 不要求蓝色像拼图一样完全填满圆孔。相机与雷达光心不重合，近距离会出现真实
  遮挡视差，孔边少量蓝色月牙或溢出是正常的。
- 不检查 MID-70 花瓣扫描线是否水平、对称或呈矩形。

当前相机焦距约 `916 px`，可用下列数量级判断：

```text
0.1 deg 旋转误差约为 1.6 px
0.5 deg 旋转误差约为 8 px
5 mm 平移误差在 1 m 处约为 4.6 px
10 mm 平移误差在 1 m 处约为 9.2 px
```

验收目标：

- `2-3 m` 明显深度边缘平均误差不超过 `3-5 px`；
- `0.7-1.0 m` 除遮挡边缘外不超过 `5-8 px`；
- 不存在稳定的 `10 px` 以上同方向系统偏移；
- 最终平移与实物安装尺寸大致一致，不出现大旋转和大平移在单一距离互相抵消。

## 9. 候选参数迭代记录

### 原始联合标定

```text
Pcl = [20.363, 70.108, -40.996] mm
```

对应 `config/mid70_d435i.yaml`。三次单场 FAST-Calib 结果最大离散曾达到约
`3.10 deg / 49.3 mm`，联合 RMSE 约 `4.2 mm`，所以联合 RMSE 本身不能证明完整
六自由度外参可靠。

### 早期手调

第一次只将 `Pcl.z` 增加 `9 mm`，LIVO 外参仍不正确。随后一次手调得到约：

```text
Pcl = [23.930, 28.641, -44.962] mm
相对当时基准 dRPY = [-3.92, -1.98, 0.00] deg
```

该组仍发生 LIVO 漂移。

### 第三组候选，已备份

```text
Rcl = [-0.024825560585,  0.999690304482, -0.001728197167,
        0.028339343715,  0.002431791152,  0.999595402145,
        0.999290034544,  0.024766540243, -0.028390937725]
Pcl = [0.012832627833, 0.009328236469, -0.044297708337]
```

备份文件：

```text
config/mid70_d435i_manual_backup_v3_20260806.yaml
```

### 第四组候选，当前工作基准

```text
Rcl = [-0.040001541432,  0.999198274262, -0.001638717223,
        0.005835299332,  0.001873609536,  0.999981219258,
        0.999182578894,  0.039991227768, -0.005905568291]
Pcl = [0.029000396045, 0.053823139714, -0.043876547149]

extrinsic_R = [-0.038499618650,  0.999252597065, -0.003467941993,
                0.009299504907,  0.003828655558,  0.999949429023,
                0.999215341441,  0.038465421543, -0.009439956205]
extrinsic_T = [0.008435800881, 0.058602885587, -0.032516474443]
```

相对原始联合标定，第四组的等效旋转增量约为
`[-1.75, -3.37, -0.09] deg`，`Pcl` 变化约为 `[+8.6, -16.3, -2.9] mm`。
当前工作文件为 `config/mid70_d435i_manual_candidate.yaml`。

## 10. 用候选参数测试 LIVO

停止投影节点后执行：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch \
  rviz:=true \
  use_camera:=true \
  image_rate:=10.0 \
  vio_state_update:=true \
  vio_diagnostics:=true \
  manual_extrinsics:=true
```

测试顺序：

1. 静止 10 秒，检查地图和位姿是否自行移动。
2. 原地缓慢旋转。
3. 缓慢前后、左右平移。
4. 正常速度组合运动并回到起点。
5. 漂移时保存 `[ VIO DIAG ]` 输出，重点看视觉点数、更新前后 RMSE 和单帧位姿增量。

恢复原始联合标定：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch \
  rviz:=true use_camera:=true image_rate:=10.0 \
  manual_extrinsics:=false
```

仅隔离视觉 EKF 位姿更新：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch \
  rviz:=true use_camera:=true image_rate:=10.0 \
  vio_state_update:=false vio_diagnostics:=true \
  manual_extrinsics:=true
```

## 11. 更新候选时的保护规则

1. 按 `S` 保存完整输出，不要只记录 `delta_*`。
2. 覆盖工作候选前，先将上一组复制为独立、带版本号的备份。
3. 只修改 `mid70_d435i_manual_candidate.yaml`，不覆盖 `mid70_d435i.yaml`。
4. 将工作候选同步到容器对应路径。
5. 使用 `roslaunch --dump-params` 确认实际加载的 `Rcl/Pcl` 与预期一致。
6. 重启投影或 mapping 节点后再测试，ROS 参数不会让已运行节点自动切换外参。

投影画面中的 `dt` 是所选图像与 LiDAR 扫描中点的时间差。静态手调时约
`-15~-20 ms` 不会形成空间错位；动态情况下该数值不能忽略，空间外参确认后需要
单独验证图像时间偏移和 D435i 彩色相机滚动快门影响。
