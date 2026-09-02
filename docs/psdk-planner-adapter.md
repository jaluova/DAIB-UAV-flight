# Planner 到 DJI Joystick 的转换

planner 的 `traj_server` 发布 `quadrotor_msgs/PositionCommand`。其中：

```text
position     目标位置
velocity     轨迹当前速度，单位 m/s
acceleration 轨迹当前加速度
yaw          目标偏航角
yaw_dot      偏航角速度，单位 rad/s
```

PSDK 速度 Joystick 使用：

```text
{ x, y, z } = { velocity.x, velocity.y, velocity.z }
`yaw` is the closed-loop rate generated from target yaw and odometry.
```

其中 DJI 的 `yaw` 速度单位是 `deg/s`。当前适配器不再直接转发
planner 的 `yaw_dot`，而是用 `position_cmd.yaw` 与 odom 的实际机头角做
闭环，再按限制输出 yaw 速度：

```text
yaw_error = shortest_angle(position_cmd.yaw - odom_yaw)
yaw_dji = clamp(kp * yaw_error, -yaw_limit, yaw_limit)
```

适配器当前默认行为：

- planner 世界坐标速度转换到机体坐标；
- 当前实机 FAST-LIVO odom 的 `child_frame_id` 是 D435 IMU optical 轴时，使用 `odom_child_optical:=true` 做完整轴变换：`FRU x=optical z`、`FRU y=optical x`、`FRU z=-optical y`；
- 按现场 DJI 约定将 body `y` 和 `yaw` 正方向取反（`+y` 右移、`+yaw` 右转）；
- 可通过 `body_yaw_offset_deg` 修正 odom child frame 与飞机 FRU 机头方向的固定航向偏置，默认 `0`；
- 水平速度限制为 `0.5 m/s`；
- 垂直速度限制为 `0.2 m/s`；
- 偏航速度默认限制为 `3 deg/s`，并限制偏航加速度为 `3 deg/s^2`；
- 目标 yaw 误差小于 `1 deg` 时停止转动；
- 指令超过 `0.2 s` 未更新时输出全零；
- ROS 节点输出 `geometry_msgs/TwistStamped`，`angular.z` 使用 ROS 标准 `rad/s`。

若现场 DJI Bridge 使用 ROS/FLU 的正方向，可启动时将
`dji_y_sign:=1.0 dji_yaw_sign:=1.0` 恢复为不取反。

实现位置：

```text
src/DAIB-Planner/src/planner/psdk_velocity_adapter/
```

运行时链路默认已经对齐：

```text
/daib_ego/position_cmd -> psdk_velocity_adapter_node -> /psdk/velocity_command
```

启动转换节点：

```bash
roslaunch psdk_velocity_adapter adapter.launch
```

当前 Orange Pi 的 FAST-LIVO 配置使用 D435 IMU optical frame，启动时应保持：

```bash
roslaunch psdk_velocity_adapter adapter.launch odom_child_optical:=true
```

这不是交换消息里的两个数，而是先用 odom 四元数把世界速度变回 optical child frame，再按
`x_f=z_o, y_f=x_o, z_f=-y_o` 转成 DJI FRU。若 odom 改成标准 FRU/FLU 机体 frame，才应设置
`odom_child_optical:=false` 并使用 `body_yaw_offset_deg`。

现场只观察箭头时，可试验传感器坐标到飞机机头的候选偏置：

```bash
roslaunch psdk_velocity_adapter adapter.launch body_yaw_offset_deg:=-90
```

只有当青色 `/psdk/velocity_direction_dji_world` 箭头与实际机头方向一致时，才将该偏置写入部署配置。不要通过交换 `x/y` 代替航向标定。

检查 planner 输出和转换结果：

```bash
rostopic echo /daib_ego/position_cmd
rostopic echo /psdk/velocity_command
rostopic echo /psdk/yaw_control_debug
```

`/psdk/velocity_command` 仍然只是 `geometry_msgs/TwistStamped`，不会调用
PSDK，也不会控制飞机。真正连接 PSDK 还需要单独的 Bridge。

板端可选输出一个经过校验的 UDP 数据包，但默认关闭：

```bash
roslaunch psdk_velocity_adapter adapter.launch \
  udp_enabled:=true udp_host:=<MANIFOLD_IP> udp_port:=19090
```

该 UDP 包只承载限幅后的 `{x,y,z,yaw}`，接收端必须先使用 dry-run 接收器验证。
协议、CRC、序号、时间戳和 200 ms 超时规则见
`docs/psdk-udp-bridge-ground-test.md`。在 Manifold 接收器通过地面测试前，不能把
数据接入 DJI API。

本地转换单元测试：

```bash
g++ -std=c++14 -I src/DAIB-Planner/src/planner/psdk_velocity_adapter/include \
  src/DAIB-Planner/src/planner/psdk_velocity_adapter/test/velocity_adapter_test.cpp \
  -o /tmp/velocity_adapter_test
/tmp/velocity_adapter_test
```

注意：坐标轴正方向必须用实际 odometry 和 DJI 地面坐标做一次标定；在确认前不能直接把 planner 的 `x/y` 发送给飞机。

现场只观察、不接飞机的完整流程见：

```text
docs/planner-adapter-dry-run-20260824.md
```
