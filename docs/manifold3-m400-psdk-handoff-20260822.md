# Manifold 3 + DJI M400 PSDK 交接记录

日期：2026-08-22  
平台：DJI Matrice M400 + Manifold 3 载荷计算机  
系统：Ubuntu 20.04.6 LTS，`aarch64`

本文记录 Manifold 3 上 DJI Payload SDK（PSDK）的现场配置、编译和安全测试结果。
PSDK 当前仍是独立于 DAIB ROS/Orange Pi 链路的终端 Demo，尚未接入本仓库的
`/daib_ego/position_cmd` 或任何自动飞控控制器。

## 设备与连接

- SSH 用户：`dji`
- USB/RNDIS：`192.168.42.140`
- Wi-Fi：`10.82.172.53`，接口 `wlan0`
- Wi-Fi 当前通过 DHCP 获取地址；地址变化时在 Manifold 3 上执行：

  ```bash
  ip -4 addr show wlan0
  ```

- Wi-Fi 目前已验证 2.4 GHz；5 GHz 网络曾扫描到但未能激活。
- USB/RNDIS 适合初始配置和故障恢复；当前 Wi-Fi SSH 命令：

  ```bash
  ssh dji@10.82.172.53
  ```

环境检查已确认 `git 2.25.1`、`cmake 3.16.3`、`gcc/g++ 9.4.0`、
`aarch64-linux-gnu-gcc/g++ 9.4.0` 和 `/system/bin/dji_app_ctl` 可用。`/home`
剩余空间约 9.1 GB。设备原有 DJI 应用为 `Smart3DExplore 00.01.00.16`。

## PSDK 源码与 App 配置

Manifold 3 直接访问 GitHub 失败（`No route to host`），因此从 WSL 下载 ZIP 后经
SCP 上传。源码位于：

```text
~/Payload-SDK
```

本次使用的 DJI Developer 应用信息：

```text
user_app_id: 193620
app_name: DAIB-M400测试
```

App Key、License 和 Developer Account 等敏感信息不写入仓库文档。

实际修改的 PSDK 文件：

| 文件 | 修改 |
| --- | --- |
| `samples/sample_c/platform/linux/manifold3/app_json/app.json` | 将 DPK 元数据的 `user_app_id` 从 `164884` 改为 `193620`；版本仍为 `01.00.00.00`，平台仍为 `manifold3`。 |
| `samples/sample_c/platform/linux/manifold3/application/dji_sdk_app_info.h` | 写入本 DJI Developer 应用身份。 |
| `samples/sample_c++/platform/linux/manifold3/application/dji_sdk_app_info.h` | 写入相同的 C++ Demo 应用身份。 |
| `samples/sample_c++/module_sample/flight_controller/test_flight_controller_command_flying.cpp` | 保留 `M` 获取 OSDK/PSDK Joystick 控制权，新增 `U` 主动释放控制权。 |
| `samples/sample_c/module_sample/flight_control/test_flight_control.c` | 增加遥控器夺权中止和正常释放控制权状态处理。 |

## 编译、安装与运行

编译：

```bash
cd ~/Payload-SDK/build
cmake .. -DUSE_SYSTEM_ARCH=LINUX
cmake --build . -j2
```

已生成：

```text
~/Payload-SDK/build/bin/dji_sdk_demo_on_manifold3
~/Payload-SDK/build/bin/dji_sdk_demo_on_manifold3_cxx
~/Payload-SDK/build/dpk/psdk-demo_v01.00.00.00.dpk
```

C Demo DPK 已安装为 `psdk-demo 01.00.00.00`。现场测试实际运行的是：

```bash
cd ~/Payload-SDK/build/bin
./dji_sdk_demo_on_manifold3_cxx
```

不要同时运行已安装的 `psdk-demo` 和 SSH 启动的 Demo。重新编译不会自动更新已安装
DPK；只有再次执行 `dji_app_ctl install -i ...` 才会更新安装版本。

主菜单中 `1` 才是飞控样例；进入飞控子菜单后，子菜单 `1` 是自动起飞/悬停/降落，
子菜单 `2` 才是位置控制。直接在主菜单输入 `2` 进入的是 HMS 菜单。

## 已验证能力

### 控制权

- C++ 键盘程序中 `M` 获取 OSDK/PSDK Joystick 控制权成功。
- 遥控器切换模式后，控制权立即回到 RC；典型日志为：

  ```text
  Current joystick ctrl authority is reset to rc due to rc switching mode
  ```

- 控制权已经回到 RC 后再按 `U` 报告“当前没有 Joystick 权限”是正常现象。

### 官方自动流程

主菜单 `1` -> 飞控子菜单 `1` 已多次验证：

```text
获取控制权 -> 电机启动 -> 上升约 1.2 m -> 悬停约 4 秒
-> 自动降落 -> 释放控制权
```

### 遥控器夺权中止

`test_flight_control.c` 增加了：

- `s_flightControlAbortRequested`：检测 RC 切模式、Pause、返航、低电量、SDK 丢失等
  控制权重置事件；
- `s_flightControlReleaseInProgress`：正常释放控制权时不误报 Safety；
- 起飞、悬停、降落循环中的周期性中止检查。

夺权后日志出现：

```text
[Safety] Joystick authority left OSDK; abort current flight-control sample
```

程序会结束当前样例并返回菜单，不再继续发送自动降落或释放已经不属于 OSDK 的权限。
飞机后续由遥控器负责人决定悬停、降落或继续飞行。

## 当前限制与下一步

- 键盘初始化日志仍显示 `Get flying speed is [5.00]`。此前尝试改为 `1 m/s` 未在运行
  日志中生效，因此不要使用键盘方向键、`R` 起飞、`B` 电机或 `P` 紧急停桨进行飞行。
- 菜单 `2/3/4` 仍是官方位置、返航和速度样例，未完成安全改造；源码中的公共中止标志
  会影响它们。
- 已观察到：菜单 `1` 夺权后中止，再运行菜单 `2` 可能立即显示 `Take off failed`；
  菜单 `2` 夺权本身能结束位置移动。这是中止标志复位范围问题，不是飞机或飞控硬件故障。
- 下次先隔离或正确初始化每次飞控样例的权限状态，再复测菜单 `1` 的夺权中止和正常
  完成；在此之前不要继续测试菜单 `2/3/4`。
- 运行中出现 `semaphore wait timeout`、`send msg to queue error` 或
  `connect status async timeout` 时，不要开始新的飞行任务；先确保飞机由遥控器控制并
  安全落地，再退出 Demo，必要时重新建立连接。

## 与本仓库的边界

本次 PSDK 工作没有修改 DJI 飞控固件、遥控器固件、`dji_app_ctl`、`Smart3DExplore`
或系统网络服务，也没有实现 GUI。它也没有改变本仓库当前的 Orange Pi/ROS 启动脚本。

DAIB 的 Explorer/EGO 观察脚本仍将规划输出隔离在
`/daib_observe/position_cmd_unconnected`，不会自动连接 PX4、MAVROS、DJI SDK 或
PSDK。后续若要把 DAIB 规划结果接入 M400，必须另行实现并验证 DJI 控制适配器、控制权
状态机、指令超时、急停和人工夺权链路，不能直接把 Planner 话题当作飞行指令。
