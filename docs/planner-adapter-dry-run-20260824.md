# Planner 到四元组 Dry-Run 测试

这次测试只验证：

```text
传感器/SLAM odom
-> Explorer 目标
-> EGO B-spline
-> PositionCommand
-> PSDK velocity adapter
-> {x, y, z, yaw} 对应的 TwistStamped
```

不启动 PSDK，不获取飞控权限，不连接飞机控制，也不发送电机或运动指令。

## 0. 前提

在 ROS1 工作空间中确认已编译并加载 Planner 和 adapter：

```bash
cd ~/catkin_ws
catkin_make -DCMAKE_BUILD_TYPE=Release -j1
source devel/setup.bash
```

如果实际工作空间不是 `~/catkin_ws`，替换为板端真实路径。确认包可见：

```bash
rospack find ego_planner
rospack find daib_explorer
rospack find psdk_velocity_adapter
```

三条命令都应返回路径。

## 1. 启动顺序

保持四个终端打开，并在每个终端先执行：

```bash
source /opt/ros/noetic/setup.bash
source ~/catkin_ws/devel/setup.bash
```

### 终端 1：FAST-LIVO / 传感器

使用实际传感器对应的 launch。以 MID-70 + D435i 配置为例：

```bash
roslaunch fast_livo mapping_mid70_d435i.launch rviz:=false use_camera:=true
```

启动后保持传感器静止约 5 秒。另开终端检查：

```bash
rostopic hz /daib_slam/odom
rostopic hz /daib_slam/planning_cloud
rostopic echo -n 1 /daib_slam/odom
```

预期：odom 和 planning cloud 持续发布，odom 的 frame 应为 `camera_init` 或系统实际配置的本地世界坐标系。

### 终端 2：EGO Planner

先启动 Planner，使它先订阅 cloud 和 odom：

```bash
roslaunch ego_planner daib_single_uav.launch
```

这个 launch 不连接 PX4、PSDK 或 M400，不会让飞机运动。

### 终端 3：Explorer

```bash
roslaunch daib_explorer explorer.launch
```

检查目标和 bridge 状态：

```bash
rostopic echo -n 1 /daib_explorer/goal
rostopic echo -n 1 /daib_ego/bridge_state
```

bridge 出现 `GOAL_FORWARDED` 后，EGO 才会尝试生成轨迹。

### 终端 4：速度转换层

```bash
roslaunch psdk_velocity_adapter adapter.launch
```

该节点只发布 ROS 消息：

```text
/psdk/velocity_command   geometry_msgs/TwistStamped
```

它不会调用任何 DJI PSDK API。

## 2. 观察 B-spline 和四元组输出

在终端 5 或 Foxglove/RViz 中检查：

```bash
rostopic info /daib_ego/position_cmd
rostopic hz /daib_ego/position_cmd
rostopic echo -n 5 /daib_ego/position_cmd
```

同时检查 adapter 输出：

```bash
rostopic info /psdk/velocity_command
rostopic hz /psdk/velocity_command
rostopic echo -n 10 /psdk/velocity_command
```

应看到：

- `/daib_ego/position_cmd` 有 `quadrotor_msgs/PositionCommand` 发布者；
- `velocity.x/y/z` 和 `yaw_dot` 随 B-spline 连续变化；
- `/psdk/velocity_command` 以约 20 Hz 发布 `TwistStamped`；
- `linear.x/y/z` 不超过 `0.5/0.5/0.2 m/s`；
- `angular.z` 对应的偏航角速度不超过 `10 deg/s`；
- odom yaw 变化时，水平速度会按世界坐标到机体坐标旋转；
- planner 停止更新超过 `0.2 s` 后，输出四元组应归零。

当前 ROS 输出中的 `angular.z` 是标准 `rad/s`。换算成 DJI 命令时再转为 `deg/s`。

## 3. 结果判定

### 通过

满足以下全部条件：

```text
odom 持续发布
目标被 bridge 接受
B-spline/PositionCommand 持续发布
adapter 持续发布 TwistStamped
速度和 yaw 均被限幅
消息停止后输出归零
全程无 PSDK 日志、无权限获取、无飞机动作
```

### 暂停并记录

出现以下任一情况就停止本次测试，不接飞机：

- `/daib_slam/odom` 没有数据或时间戳不前进；
- planner 进入 `EMERGENCY_STOP` 或持续 `plan_success=0`；
- `/daib_ego/position_cmd` 没有发布者；
- adapter 输出持续为无效/全零，但 planner 明确在发布有效速度；
- 速度超过限幅，或消息停止后仍保持非零；
- ROS 节点崩溃或出现连续通信错误。

## 4. 重要边界

这次测试只证明：

```text
传感器 -> SLAM -> Planner -> B-spline -> PositionCommand -> 转换层
```

不能证明飞机会跟随，也不能证明坐标轴已经完成实机标定。只有之后单独实现并审查 PSDK Bridge，才允许把输出接到 `DjiFlightController_ExecuteJoystickAction()`。
