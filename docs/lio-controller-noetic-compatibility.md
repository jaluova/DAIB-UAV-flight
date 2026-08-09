# LIO-Drone-250 Controller 与 Noetic/PX4 兼容性

日期：2026-08-01

> 2026-08-03更新：`patches/lio-drone-250-controller-safety.patch`已实现下述
> 阻断项中的状态初始化、命令超时固定悬停、服务返回值、yaw rate、默认禁止自动
> 解锁、`Kvel_y`和日志修复，并在`ros1-rviz`中Release构建通过。仿真飞行门禁仍
> 未解除，必须完成本文末尾的状态机和唯一setpoint发布者验收。

## 范围与结论

本轮只评估并编译控制器，不启动 EGO、FAST-LIVO2 或 Explorer，也不执行解锁
和起飞。

候选为 LIO-Drone-250 提交
`a0614d54d96ee069128bc0132db381e0ea50ac44` 内的
`geometric_controller`。它源自 `Jaeyoung-Lim/mavros_controllers`，但增加了
`quadrotor_msgs/PositionCommand` 输入和起飞、保持、降落状态。

结论：ROS Noetic 与 MAVROS 1.20.1 编译兼容，PX4 1.13 所需 MAVROS 接口仍然
存在；原样代码的失效保护和状态机不满足阶段 B 验收，当前不得直接起飞。

上游 `Jaeyoung-Lim/mavros_controllers` 提交
`8b3fff0327b56c415aa24708bea5f37d76307404` 也已在独立
`/root/mavros_controllers_ws` 中无补丁 Release 编译通过。上游版本控制实现更
完整，但输入是 Pose/FlatTarget/MultiDOF trajectory，不含 LIO fork 增加的
`quadrotor_msgs/PositionCommand` 回调，不能不经适配直接接当前 EGO。

## 独立工作区

容器内工作区为 `/root/lio_controller_ws`：

```text
/root/lio_controller_ws/
├── src/
│   ├── controller_msgs -> ../vendor/LIO-Drone-250/src/controller/controller_msgs
│   └── geometric_controller -> ../vendor/LIO-Drone-250/src/controller/geometric_controller
└── vendor/LIO-Drone-250/     # 固定提交，完整源码不进入 ROS_PACKAGE_PATH
```

在主机一键重建：

```bash
cd /home/ufd/cc-chat
./scripts/build_lio_controller_ws.sh
```

脚本应用 `patches/lio-drone-250-noetic-controller.patch` 补齐 catkin 直接依赖，
随后仅对白名单 `controller_msgs;geometric_controller` 做 Release 构建。它不会
编译或启动 FAST-LIO。

上游对照工作区可单独重建：

```bash
./scripts/build_mavros_controllers_ws.sh
```

## 消息兼容性

LIO 仓库内的 `quadrotor_msgs/PositionCommand.msg` 比当前 XTDrone/EGO 版本多：

```text
geometry_msgs/Vector3 jerk
```

两者 ROS1 MD5 不同，不能直接建立 publisher/subscriber 连接。控制器回调未读取
`jerk`，所以本工作区不构建 LIO 的消息包，直接使用当前 EGO 已构建版本：

```text
package: /root/xtdrone_ego_ws/src/Utils/quadrotor_msgs
MD5:     4712f0609ca29a79af79a35ca3e3967a
```

这保留了 position、velocity、acceleration、yaw 和 yaw_dot。LIO 回调目前读取
前四项，但 `yaw_dot` 的赋值被注释，接入 EGO 前仍需恢复或明确 mask 策略。

## MAVROS/PX4 接口

控制器使用相对名称，阶段 B 必须放在 `/iris_0` namespace 下：

| 方向 | 控制器名称 | 阶段 B 实际名称 | 类型 |
|---|---|---|---|
| 订阅 | `mavros/state` | `/iris_0/mavros/state` | `mavros_msgs/State` |
| 订阅 | `mavros/local_position/pose` | `/iris_0/mavros/local_position/pose` | `geometry_msgs/PoseStamped` |
| 订阅 | `mavros/local_position/velocity_local` | `/iris_0/mavros/local_position/velocity_local` | `geometry_msgs/TwistStamped` |
| 发布 | `command/bodyrate_command` | `/iris_0/mavros/setpoint_raw/attitude` | `mavros_msgs/AttitudeTarget` |
| 服务 | `mavros/cmd/arming` | `/iris_0/mavros/cmd/arming` | `mavros_msgs/CommandBool` |
| 服务 | `mavros/set_mode` | `/iris_0/mavros/set_mode` | `mavros_msgs/SetMode` |

raw attitude 消息设置 `type_mask=128`，即忽略姿态 quaternion，向 PX4 发送机体
角速度与归一化推力。MAVROS 1.20.1 可编译该接口，PX4 1.13 支持对应的
`SET_ATTITUDE_TARGET`；这不代表当前增益和归一化推力参数已经适配 iris SITL。

## 起飞前阻断项

1. `received_home_pose` 未初始化，状态机初态存在未定义行为。
2. PositionCommand 超时检查整段被注释，命令中断后会永久执行最后一条姿态/推力命令。
3. `landCallback` 和 `ctrltriggerCallback` 声明返回 `bool`，实现却无 return；编译已有警告。
4. `yaw_dot` 未接入，launch 又设置 `velocity_yaw=true`，会覆盖 EGO yaw。
5. 起飞、保持、降落发布 position setpoint，轨迹阶段发布 raw attitude setpoint；切换条件和超时必须明确测试。
6. `enable_sim=true` 时节点会自行切 OFFBOARD 并解锁，正式 launch 必须默认关闭自动解锁。
7. 动态调参回调把 `Kvel_` 的 y 分量错误写成 `Kvel_z_`。
8. 控制循环以 100 Hz 向 stdout 连续打印，可能造成日志和时序抖动。

LIO fork 编译时明确出现第 3 项的两个警告。其现有 5 个 gtest 均通过，但只
覆盖 `acc2quaternion`、velocity yaw 和示例字符串函数，没有覆盖上述状态机、
MAVROS 输出或失效保护，因此不能据此解除阻断。

因此下一步不是接 EGO，而是制作阶段 B 专用 launch 和安全补丁，先完成：初始
position setpoint 预流、人工解锁、1 m 起飞、30 秒保持、命令超时转保持、
`AUTO.LAND`、自动上锁，并用 `rostopic info` 确认 MAVROS setpoint 只有该节点
一个外部发布者。

## Enhanced communication 的边界

`multirotor_communication_enhanced.py` 的比例保持只处理 `cmd_vel_flu` 和
`cmd_vel_enu`。当前 XTDrone EGO 基线走 `cmd_pose_enu`，因此 enhanced 与原版
对该链路输出相同的纯位置 setpoint，不会恢复 EGO 的速度/加速度前馈。

阶段 B 启动 geometric controller 时必须完全停止两种 communication 脚本。
enhanced 可用于独立键盘速度测试，但不能与 controller 叠加，也不能代替
controller 的 PositionCommand 超时保护。
