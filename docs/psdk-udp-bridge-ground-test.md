# Orange Pi 到 Manifold PSDK UDP 地面联调

接收器默认是 dry-run。只有在妙算 `u` 菜单中显式按 `L` 武装、再按 `M` 获取
PSDK Joystick 控制权后，才会调用 DJI 速度控制 API。

## 协议和保护

- UDP 端口：`19090`
- 发送频率：adapter 的 `20 Hz`
- 数据：限幅后的 `{x_mps, y_mps, z_mps, yaw_deg_s}`
- 校验：magic、版本、消息类型、长度、CRC32、递增序号和发送时间戳
- 接收超时：`200 ms`，超时只产生一次中性 `{0,0,0,0}`
- 接收器限幅：水平 `0.1 m/s`、垂直 `0.05 m/s`、yaw `0 deg/s`
- adapter 的 `udp_enabled` 默认 `false`

## 1. Manifold dry-run 接收

将 `tools/psdk_velocity_udp_receiver.py` 复制到 Manifold 后执行：

```bash
python3 psdk_velocity_udp_receiver.py \
  --bind 0.0.0.0 \
  --port 19090 \
  --timeout-ms 200 \
  --horizontal-limit 0.1 \
  --vertical-limit 0.05 \
  --yaw-limit 0
```

看到 `DRY_RUN listening` 后保持终端运行。此程序不链接 DJI SDK。

## 2. Orange Pi 发送

把 `<MANIFOLD_IP>` 替换成 Orange Pi 可以直接访问的 Manifold 地址：

```bash
roslaunch --screen psdk_velocity_adapter adapter.launch \
  odom_child_optical:=true \
  dji_y_sign:=-1 \
  horizontal_limit_m_s:=0.1 \
  vertical_limit_m_s:=0.05 \
  yaw_limit_deg_s:=0 \
  udp_enabled:=true \
  udp_host:=<MANIFOLD_IP> \
  udp_port:=19090
```

Manifold 应连续显示 `RECV dry_run=1`。停止 Orange Pi adapter 后，Manifold 应在
`200 ms` 左右显示一次 `NEUTRAL reason=timeout`。

## 3. 允许进入 DJI API 集成的条件

以下全部通过前，不得把接收值传给 `DjiFlightController_ExecuteJoystickAction()`：

1. 连续接收至少 5 分钟，没有 CRC、乱序或时间戳错误。
2. 停止发送、断网和杀死 adapter 都能在 200 ms 内产生中性指令。
3. 超限包被拒绝，不能进入命令回调。
4. Manifold 上已经验证的 `IDLE -> ACTIVE -> ABORTED` 权限状态机可复用。
5. 只有 `ACTIVE` 状态才能调用 DJI API；`IDLE/ABORTED` 必须禁止发送。
6. RC 切模式或 Pause 触发 `ABORTED`，之后必须人工确认才能再次获取权限。

当前接收器仅完成前四项中的网络输入验证，不具备飞行能力。

## 4. 本地 Payload-SDK 的妙算侧 bridge

本机同级目录 `../Payload-SDK` 已包含 Manifold3 C++ Demo 和现有权限安全状态机。
新增的 `u` 菜单默认只打印；只有 `L` 和 `M` 都完成后才调用
`DjiFlightController_ExecuteJoystickAction()`：

```text
主菜单选择 u
L  武装/解除 DJI API 输出（默认解除）
M  获取 PSDK 权限；必须先 L 才会实际发控制量
U  停止输出并正常释放给 RC
A  停止输出并确认 ABORTED
Q  退出接收器（必须先 U）
```

接收端固定监听 `0.0.0.0:19090`，检查 DAIB 头、CRC、序号、有限浮点数和当前
限幅；停止 Orange Pi 发送后约 `200 ms` 将发送值置为中性并打印一次
`NEUTRAL reason=timeout`。RC 夺权、释放权限、坏包和断档也会立即停止 DJI 输出。

妙算 C++ bridge 不逐包打印正常收包，避免终端被 20 Hz 日志淹没；只保留安全异常和
权限状态日志。Python dry-run 接收器也监听 `19090`，所以不能与 C++ bridge 同时运行；
需要详细观察包内容时，先退出 C++ bridge，再单独启动 Python 接收器。
跨设备系统时间目前不参与超时判定，超时使用妙算本地接收单调时钟，因此不受两台机器
时间差影响。
