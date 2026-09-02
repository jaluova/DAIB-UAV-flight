# Orange Pi 到 Manifold PSDK Bridge 测试流程

本文档对应当前版本的 UDP bridge。测试目标是验证：

```text
Orange Pi planner adapter
    -> UDP 192.168.177.53:19090
    -> Manifold PSDK bridge
    -> DJI ExecuteJoystickAction
```

当前默认限速：

```text
水平速度：0.1 m/s
垂直速度：0.05 m/s
yaw 角速度：0 deg/s
```

`yaw_limit_deg_s:=0` 表示本轮不会发送偏航动作。四元组单位为：

```text
{x[m/s], y[m/s], z[m/s], yaw[deg/s]}
```

## 0. 安全要求

- 第一次测试必须在地面完成，电机关闭。
- `L` 是真实 DJI API 输出的武装开关；不要在未确认链路前按 `L`。
- `M` 会获取 PSDK Joystick 控制权；获取后飞手必须能立即切换 RC 模式或按 Pause。
- 程序不会自动起飞、降落或解锁电机。
- 任何方向异常、通信异常、权限无法释放或日志持续报错，立即按 `U`，必要时由飞手切换 RC。
- Python dry-run 和 C++ bridge 都监听 UDP `19090`，同一时间只能运行一个。

## 1. 网络检查

### 1.1 Manifold 地址

在 Mac/开发机上确认妙算 SSH 和端口：

```bash
ping -c 10 192.168.177.53
nc -uvz -w 2 192.168.177.53 19090
ssh manifold3 'hostname; ip -4 addr'
```

在 Orange Pi 上确认到妙算的路由：

```bash
ip route get 192.168.177.53
ping -c 5 192.168.177.53
```

必须确认流量走正确网卡，不能出现经 `wlan0` 绕到其它网段的情况。

## 2. Orange Pi 启动

先确认 ROS 容器：

```bash
docker ps
```

至少应有：

```text
daib-sensor-master
daib-drivers
daib-algorithm
```

确认 ROS 话题：

```bash
docker exec daib-sensor-master bash -lc '
source /opt/ros/noetic/setup.bash
rostopic list | grep -E "livox|camera|daib_ego|position_cmd"
'
```

在算法容器中启动已经编译的 adapter。下面参数保持本轮的保守限速和坐标修正：

```bash
docker exec -it daib-algorithm bash -lc '
source /opt/ros/noetic/setup.bash
source /opt/daib_ws/devel/setup.bash
roslaunch --screen psdk_velocity_adapter adapter.launch \
  odom_child_optical:=true \
  dji_y_sign:=-1 \
  horizontal_limit_m_s:=0.1 \
  vertical_limit_m_s:=0.05 \
  yaw_limit_deg_s:=0 \
  udp_enabled:=true \
  udp_host:=192.168.177.53 \
  udp_port:=19090
'
```

应看到：

```text
PSDK UDP output ENABLED to 192.168.177.53:19090
```

如果容器名称不是 `daib-algorithm`，替换为实际运行算法节点的容器名称。

## 3. Python dry-run 验证

这一阶段不调用 DJI SDK，只验证 UDP 包。先确保 C++ bridge 没有运行。

在妙算上执行：

```bash
cd ~/daib_psdk
python3 psdk_velocity_udp_receiver.py \
  --bind 0.0.0.0 \
  --port 19090 \
  --timeout-ms 200 \
  --horizontal-limit 0.1 \
  --vertical-limit 0.05 \
  --yaw-limit 0 \
  --max-packet-age-ms 200000000 \
  --max-future-skew-ms 200000000
```

预期：

```text
DRY_RUN listening on 0.0.0.0:19090
RECV dry_run=1 ...
```

检查以下行为：

1. 连续收包，序号递增。
2. `x/y` 不超过 `0.1`，`z` 不超过 `0.05`，`yaw` 为 `0`。
3. 在 Orange Pi 停止 adapter 后约 `200 ms` 出现：

   ```text
   NEUTRAL reason=timeout x=0 y=0 z=0 yaw=0
   ```

4. 重新启动 adapter 后可以重新收到包。

停止 Python 接收器：

```text
Ctrl+C
```

## 4. C++ bridge 编译和启动

妙算上的源码已经包含 UDP bridge。重新编译：

```bash
cd ~/Payload-SDK/build
cmake .. -DUSE_SYSTEM_ARCH=LINUX
cmake --build . -j2
```

必须看到：

```text
[100%] Built target dji_sdk_demo_on_manifold3_cxx
```

启动 Demo：

```bash
cd ~/Payload-SDK/build/bin
./dji_sdk_demo_on_manifold3_cxx
```

进入菜单：

```text
1 -> u
```

bridge 默认只接收和校验，不调用 DJI 运动 API。正常收包不会逐包打印，只在异常时打印日志。

## 5. C++ bridge dry-run 和权限验证

进入 `u` 后，先保持输出关闭：

```text
不要按 L
```

此时可以确认 Orange Pi 仍在发送，但飞机不应收到运动控制调用。

验证权限状态机：

```text
M
```

预期：

```text
PSDK authority confirmed; state=ACTIVE
```

然后释放：

```text
U
```

预期：

```text
Normal release confirmed; state=IDLE
```

测试 RC 夺权：

```text
M
```

由飞手切换 RC 模式或按 Pause。预期：

```text
state=ABORTED
```

确认后：

```text
A
```

预期回到 `IDLE`。如果控制权没有按预期回到 RC，停止测试，不进入下一阶段。

## 6. 接入 DJI API 的地面验证

确认第 3、5 节均通过后，才进行这一阶段。建议电机仍关闭，先只验证 API 调用返回值。

在 `u` 菜单中按：

```text
L
M
```

含义：

- `L`：武装 DJI API 输出，但不会单独获取控制权。
- `M`：获取 PSDK 控制权。
- 只有 `L=armed` 且状态为 `ACTIVE` 时，控制线程才会以 20 Hz 调用
  `DjiFlightController_ExecuteJoystickAction()`。

此时应观察：

```text
live=1 authority state=ACTIVE
```

由于当前 `yaw` 限制为 0，接收的运动量只有低速 `x/y/z`。停止 Orange Pi adapter 后，约
`200 ms` 内发送值会变成 `{0,0,0,0}`。C++ bridge 不会打印每个中性调用，因此以超时日志和
飞控 API 错误日志判断状态。

停止真实输出：

```text
U
```

`U` 会先解除 live output，再释放控制权给 RC。正常结束后：

```text
L   （如仍为 armed，按一次解除）
Q
```

如果 RC 夺权：

```text
自动进入 ABORTED
按 A 确认
```

## 7. 低速悬停测试前检查

只有地面 API 验证没有错误后，才允许进行短时悬停测试：

1. 飞手确认 RC 可随时夺权，飞行模式和 Pause 操作已确认。
2. Orange Pi adapter 使用 `0.1/0.05/0` 限速。
3. 妙算进入 `u`，先 `L`，再 `M`。
4. 飞手手动起飞并悬停，程序不负责起飞。
5. 只观察很短时间的低速 `x/y/z` 响应，不测试 yaw。
6. 任何异常立即切 RC；测试结束按 `U`，由飞手降落。

测试完成后退出：

```text
U
Q
```

## 8. 故障处理

### 端口占用

```bash
sudo ss -lunp | grep 19090
```

停止占用端口的 Python 接收器或 C++ bridge，只保留一个监听者。

### 没有收包

Orange Pi 检查：

```bash
docker logs --tail 50 daib-algorithm
ip route get 192.168.177.53
```

妙算检查：

```bash
ss -lunp | grep 19090
```

### 出现 `sequence_gap`

先停止真实 API 输出，按 `U` 释放控制权。检查 Wi-Fi、网卡路由和 CPU 负载；不要在出现持续
丢包时继续飞行。

### 出现 `NEUTRAL reason=timeout`

这是保护动作，表示超过 `200 ms` 没有有效包。确认 Orange Pi adapter、ROS 规划输出和网络
链路恢复后，再重新执行权限和武装流程；不要自动继续依赖旧指令。

### 出现 `ABORTED`

表示控制权已经离开 PSDK，通常是 RC 切模式、Pause 或其它飞控安全事件。保持 RC 接管，确认
飞机状态安全后再按 `A`，不要直接重新按 `L/M`。

## 9. 通过标准

本轮 bridge 测试只有同时满足以下条件才算通过：

- Python dry-run 能连续收包，停止发送能在约 `200 ms` 中性归零。
- C++ bridge 能正常启动并监听 `19090`。
- `M -> ACTIVE -> U -> IDLE` 正常。
- RC 切模式/Pause 能触发 `ABORTED`，且输出自动解除。
- `L + M` 时 DJI API 调用无持续错误；超时后使用中性指令。
- 任何异常都能通过 `U` 或 RC 夺权停止输出。

未满足全部条件前，不进入自主规划器直接控制飞行测试。
