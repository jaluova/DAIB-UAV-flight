# DAIB UAV 快速启动

在香橙派上执行：

```bash
cd /mnt/huawei_ssd/daib
```

当前 Compose 将 ROS Master 放在独立的 `deploy-roscore-1` 容器中。重复执行启动脚本
只重建算法容器，并复用 `deploy-roscore-1` 和健康的 `deploy-drivers-1`，不会打断
D435i 的 USB/UVC 会话。不要手工重启驱动容器。

## 三种模式

只用 MID-70 和 D435i IMU，关闭相机参与 LIO：

```bash
./scripts/start_lio_only.sh --check-seconds 15
```

正常 LIVO，启用 D435i 图像：

```bash
./scripts/start_livo.sh --check-seconds 15
```

正常 LIVO，并启动低延迟 Foxglove 相机流：

```bash
./scripts/start_flight_stack.sh --check-seconds 15 --camera-rate 6
```

## 飞行录包

正常 LIVO 启动通过后，在第二个 SSH 终端执行：

```bash
cd /mnt/huawei_ssd/daib
./scripts/record_fast_livo_inputs.sh --min-free-gb 20
```

默认录算法使用的约 10 Hz 图像。若要把接近实时的相机画面带回电脑，使用：

```bash
./scripts/record_fast_livo_inputs.sh --min-free-gb 20 --include-raw-image
```

bag 直接写入华为 SSD：

```text
/mnt/huawei_ssd/bags/fast_livo_real/<日期时间>/
```

录制 `/livox/lidar`、`/camera/imu` 和 FAST-LIVO 实际使用的 10 Hz 彩色图像；打开
`--include-raw-image` 后还会录制约 30 Hz 的 `/camera/color/image_raw`，代价是 bag
体积明显增大。
结束飞行后先在录包终端按 `Ctrl+C`，必须等待：

```text
[PASS] Recording finalized
```

再停止算法和驱动。不要在存在 `.bag.active` 时断电。2026-08-18 实测 59.1 秒
产生约 1.1 GiB；当前保留 20 GiB 空间时，75 GiB 剩余容量约可录 45～50 分钟，
实际以脚本显示的空间为准。

### 帧率说明

- `/camera/color/image_raw` 是 D435i 原始约 30 Hz 图像。
- `/camera/color/image_fast_livo` 是算法实际消费的标称 10 Hz 图像，也是 bag 记录的图像。
- `--include-raw-image` 会额外记录约 30 Hz 的 `/camera/color/image_raw`，电脑回放时选择它即可看接近实时的画面。
- `/camera/color/image_fast_livo_foxglove` 只是 Wi-Fi 远程预览，默认 6 Hz，不写入 bag。
- `start_bag_play.sh --rate 1.0` 按实时速度回放；`--rate 0.5` 只用于慢速排查。
- 回放倍率不会删除帧或改变原 bag，录制过程始终是实时的。
- 分析机体高频振动时以 bag 中约 200 Hz 的 `/camera/imu` 为主，图像用于辅助观察。

因此当前 59.1 秒测试包中的 499 张图像（约 8.44 Hz）来自算法 10 Hz 输入链路的
实际到达率，不是 Foxglove 6 Hz 限速，也不是录包时使用了慢速回放参数。若要另录
30 Hz 原始图像，应先做板端 CPU、SSD 写入和算法实时性压力测试，不应在首飞时直接
把高带宽原始图像设为默认录制项。

## 回看最新 bag

回放时必须停止实时驱动，避免真实传感器与 bag 发布同名话题。脚本会自动完成切换：

```bash
cd /mnt/huawei_ssd/daib
./scripts/start_bag_play.sh --rate 1.0
```

然后 Foxglove 连接 `ws://<香橙派Wi-Fi地址>:8765`，3D 面板 Fixed Frame 选择
`camera_init`。脚本默认选择最新录包目录，并按顺序回放该目录下的全部分卷；播放结束后
最终地图仍可查看。也可以把某个 bag 文件或录包目录作为脚本最后一个参数传入。

恢复实机 LIVO：

```bash
./scripts/start_flight_stack.sh --check-seconds 15 --camera-rate 6
```

停止算法、驱动和 Foxglove：

```bash
./scripts/stop_daib_stack.sh
```

看到以下内容才算启动检查通过：

```text
[PASS] LIO-only stack is ready
```

LIVO 模式会显示 `normal LIVO mode`。Foxglove 连接：

```text
ws://<香橙派Wi-Fi地址>:8765
```

当前脚本只启动定位和建图。Explorer、EGO-Planner、PX4/MAVROS 控制、自动探索和自动避障还没有接入当前飞行启动链路。
