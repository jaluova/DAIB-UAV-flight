# FAST-LIVO2 与 PX4 GPS local odometry 对比

日期：2026-08-01

## 数据范围

分析文件：`/root/slam_gps_compare_20260801_062046.bag`（容器
`ros1-rviz`）。有效时长 38.5 s，录制开始时飞机已经处于 `armed=True`、
`OFFBOARD` 并在运动。

主要数据：

- `/daib_slam/odom`：578 条，`camera_init -> aft_mapped`；
- `/iris_0/mavros/local_position/odom`：1158 条，`map -> base_link`；
- `/iris_0/mavros/state`：全程保持解锁和 OFFBOARD；
- `/ground_truth/odom`、`/iris_0/mavros/vision_pose/pose` 和
  `/xtdrone/iris_0/cmd_pose_enu` 均没有实际消息。

对应 PX4 ULog 为
`/root/.ros/sitl_iris_0/log/2026-08-01/06_18_58.ulg`。初始参数为
`EKF2_AID_MASK=1`、`EKF2_HGT_MODE=0`，即 PX4 1.13 的 GPS 水平辅助和气压计
高度；bag 中也没有 ROS 外部视觉注入。因此 MAVROS local odometry 可作为本轮
独立 GPS/EKF 参照，但由于没有 Gazebo ground truth，不能把任一路称为绝对真值。

## 对齐方法

两路 odometry 按 header 时间戳插值配对。位置采用前 10 s 轨迹点的二维刚体
拟合估计坐标轴旋转和平移，姿态 yaw 则单独估计固定偏移。

位置和姿态必须分开对齐。位置轨迹只需旋转约 `+0.75 deg`，而 quaternion yaw
需要约 `-7.68 deg` 偏移。若错误地用姿态偏移旋转位置，会人为制造约 1.5 m
的终点差；这不是实际 SLAM 漂移。

## 结果

| 指标 | FAST-LIVO2 | PX4 GPS/EKF |
|---|---:|---:|
| 平均频率 | 14.97 Hz | 30.01 Hz |
| 周期 p95 / max | 164 / 364 ms | 40 / 40 ms |
| receipt - header 平均 / p95 | 77.9 / 188 ms | 5.9 / 8.0 ms |
| 最大相邻位置步长 | 0.203 m | 0.032 m |
| 路径长度 | 19.339 m | 15.837 m |
| 净位移 | 11.346 m | 11.378 m |

前 10 s 对齐后的相对指标：

| 指标 | mean | p95 | max |
|---|---:|---:|---:|
| 三维位置误差 | 0.078 m | 0.128 m | 0.261 m |
| 水平位置误差 | 0.049 m | 0.102 m | 0.247 m |
| 高度绝对误差 | 0.054 m | 0.105 m | 0.169 m |
| yaw 绝对误差 | 0.180 deg | 0.448 deg | 1.180 deg |
| 速度模长差 | 0.068 m/s | 0.210 m/s | 0.544 m/s |
| 1 s 相对位置误差 | 0.039 m | 0.086 m | 0.435 m |

记录首尾的相对误差变化为 0.148 m。SLAM 与 GPS/EKF 的净位移长度只差
0.032 m，方向也基本一致，没有证据支持此前由错误对齐得到的“1.5 m 水平
漂移”。

## 结论

FAST-LIVO2 的低频位置精度已经接近 GPS/EKF：这段约 11.4 m 的运动中，水平
误差均值约 5 cm、p95 约 10 cm，航向也非常一致。这说明后续无 GPS 闭环有
现实希望达到当前低速飞行效果。

当前主要风险是实时性和平滑性，而不是长程尺度：SLAM 只有约 15 Hz，周期
最大间断 364 ms，消息平均晚到约 78 ms；其累计路径比参照多 22%，但净位移
几乎相同，符合短时位置抖动或更新不均匀，而不是尺度膨胀。直接用于控制前应
优先处理时间戳、输出调度、速度质量和短时平滑，不能只看 RViz 轨迹重合度。

## 下一次验收录制

下一次录制 60--90 s，并完整覆盖：

1. 解锁前静止 10 s；
2. 起飞至 1 m，悬停 20 s；
3. 水平飞行 2 m，悬停 10 s；
4. 返回起点，悬停 10 s；
5. 降落并等待 `armed=False` 后再停止 rosbag。

除本轮话题外，应先用 `rostopic list` 找到 Gazebo 的真实位姿/里程计话题并
确认它在发布，再加入录制；同时加入 `/daib_ego/position_cmd`。开始录制后
检查 rosbag 是否报告订阅成功并不代表有数据，需另用 `rostopic hz` 验证。
分析时应通过 `--alignment-start-seconds` 选择包含明显水平运动的窗口，不要
用起始静止或纯垂直起飞段估计水平 frame 旋转。

复现分析：

```bash
docker cp scripts/analyze_odom_comparison_bag.py \
  ros1-rviz:/tmp/analyze_odom_comparison_bag.py
docker exec ros1-rviz bash -lc \
  "source /root/catkin_ws/devel/setup.bash; \
   python3 /tmp/analyze_odom_comparison_bag.py --alignment-seconds 10 \
   /root/slam_gps_compare_20260801_062046.bag"
```
