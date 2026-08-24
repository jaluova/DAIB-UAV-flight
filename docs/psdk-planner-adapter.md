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
{ x, y, z, yaw } = { velocity.x, velocity.y, velocity.z, yaw_dot }
```

其中 DJI 的 `yaw` 速度单位是 `deg/s`，所以要执行：

```text
yaw_dji = yaw_dot * 180 / pi
```

适配器当前默认行为：

- planner 世界坐标速度转换到机体坐标；
- 水平速度限制为 `0.5 m/s`；
- 垂直速度限制为 `0.2 m/s`；
- 偏航速度限制为 `10 deg/s`；
- 指令超过 `0.2 s` 未更新时输出全零；
- ROS 节点输出 `geometry_msgs/TwistStamped`，`angular.z` 使用 ROS 标准 `rad/s`。

实现位置：

```text
src/DAIB-Planner/src/planner/psdk_velocity_adapter/
```

本地转换单元测试：

```bash
g++ -std=c++14 -I src/DAIB-Planner/src/planner/psdk_velocity_adapter/include \
  src/DAIB-Planner/src/planner/psdk_velocity_adapter/test/velocity_adapter_test.cpp \
  -o /tmp/velocity_adapter_test
/tmp/velocity_adapter_test
```

注意：坐标轴正方向必须用实际 odometry 和 DJI 地面坐标做一次标定；在确认前不能直接把 planner 的 `x/y` 发送给飞机。
