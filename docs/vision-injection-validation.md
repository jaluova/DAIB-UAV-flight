# 视觉注入 PX4 EKF 验证记录 (2026-07-31)

## 目标
验证 GPS 拒止定位链路：FAST-LIVO2 odom → republisher →
`/iris_0/mavros/vision_pose/pose` → PX4 视觉 EKF →
`/iris_0/mavros/local_position/odom`。本文只记录状态估计实验，不定义轨迹控制
方案；控制架构参见 `ego-px4-control-architecture.md`。

## 已验证结论

### 1. 环境问题与修复（本次会话根因）
- **xhost 授权**（用户指出）：宿主重启后 X access control 开启，容器内 root 连不上 DISPLAY=:1 → gzclient 崩溃 → livox 传感器管线异常 → `/scan` 不发（发布者注册了但没消息）。修复：`docker exec ros1-rviz xhost +` → gzclient 正常 → /scan 恢复 10Hz。
- **GAZEBO_PLUGIN_PATH 错误**：正确路径是 `/root/PX4_Firmware/build/px4_sitl_default/build_gazebo`（`Tools/sitl_gazebo/build` 不存在）。路径错时 mavlink_interface 插件不加载 → px4 永远卡在 "Waiting for simulator to accept connection on TCP port 4560"。
- **px4 手动启动需 `PX4_SIM_MODEL=iris`**，否则 "Unknown model" 启动失败。
- **spawn 超时是良性的**（"Entity pushed to spawn queue, but spawn service timed out"）：实体最终会出现（model_states 有 iris_0），不影响功能（sim_gui4 时 spawn 超时但一切正常）。
- 重启整套 sim 的正确命令（含全部环境变量）见 px4-full-pipeline.md 或本文件末尾。

### 2. MAVLink 通道与嗅探方法（UDP）
- **GCS 通道本地端口 = 18570**（`udp_gcs_port_local=18570+instance`，见 px4-rc.mavlink），不是 14550。14550 上收到来自 18570 的包是因为对方绑定/回发。
- 嗅探姿势：绑 `127.0.0.1:14550` → 向 `127.0.0.1:18570` 发 v1 心跳（`FE 09 00 01 01 00` + 8B 0 + CRC 0x50）→ px4 把流回发到本端口。
- **v1 帧（0xFE）**：头 8 字节（FE,len,seq,sysid,compid,msgid,payload,crc2），payload 从 i+6 开始。
- **ESTIMATOR_STATUS(230) v1 布局**：time_usec@0(8B), pos_horiz_ratio@8, pos_vert_ratio@12, vel_xy_ratio@16, vel_z_ratio@20 (float), flags@32 (uint16)。flags 位：bit0 tilt_align, bit1 yaw_align, bit12 ev_pos, bit13 ev_yaw, bit14 ev_hgt, bit15 fuse_baro。
- **VFR_HUD(74) v1 布局**：airspeed@0, groundspeed@4 (float), heading@8 (int16), throttle@10 (uint16), alt@12, climb@16 (float)。
- 注入器（UDP 直发 PX4）：绑 24541 → v2 帧发 `127.0.0.1:34580`（offboard 通道本地端口），msg 102 VISION_POSITION_ESTIMATE，CRC_EXTRA=158。时间戳用 ATTITUDE(30) 的 time_boot_ms@payload0(4B) 作 PX4 时钟基准（usec = tms*1000 - 20000）。

### 3. 重要纠错（之前结论作废）
- **之前 ulg 解析有 bug**（ADD_LOGGED_MSG 的 msg_id 误用 payload[1]、名字丢首字节）→ 以下旧结论全部是解析错位假象：
  - ~~baro 损坏（pressure=-0.0014）~~ → 真实 baro 95603 Pa（正常）
  - ~~vehicle_local_position 位置指数发散~~ → ulg 根本没记录该话题
  - ~~hgt_test_ratio 1e12~1e24~~ → 假象
  - ~~climb=488 m/s~~ → VFR_HUD 布局解析错（真实 climb=0.00, alt=0.16）
- **ulg 白名单**：rcS 里 `LOGGER_ARGS="-p vehicle_attitude"` → ulg 只记录 vehicle_attitude 相关话题，**不记录 vehicle_local_position**，无法用 ulg 验证位置。

### 4. 当前链路状态（全绿）
- /scan 10Hz ✓、板端 SLAM odom ✓（ros1_dev 容器内 `roslaunch fast_livo mapping_avia_sim.launch rviz:=false`）、republisher → vision_pose 10Hz ✓（yaw 已锁 PX4 偏航）
- mavros connected ✓、EKF2_AID_MASK=12（EV_POS+EV_VEL）、EKF2_HGT_MODE=3
- **ESTIMATOR_STATUS flags=0xaaef：tilt_align=1, yaw_align=1, ev_pos=1, ev_yaw=1, baro_hgt=1** —— EKF 在融合视觉位置！
- **mavros 的 vision_pose 插件会自动把收到的 pose 转发给 PX4**（VISION_POSITION_ESTIMATE）——republisher 持续 10Hz 就够了，无需注入器（注入器只用于测试）。
- IMU 正常（静止 z=9.824 m/s²）、baro 正常（956 hPa）。

### 5. 最终打通（关键）
- **持续注入器部署后 odom 出数**：`/iris_0/mavros/local_position/odom` 30Hz（x=0.029, y=0.011, z=0.124）。
- 关键操作：`sed` 去掉注入器 15s watchdog → 无限持续转发（PX4 时钟时间戳，10Hz）→ setsid 后台常驻。
- 原因分析：mavros 1.20 的 vision_pose 插件**没有可靠转发**（`/mavlink/to` 队列为空，px4 收到的 vision 是 2.2Hz 的畸形 245 len=2 帧，内容垃圾 → EKF 拒测 → ev_pos 时有时无）；自研持续注入器（正确时间戳 + 有效数据）解决。
- NED32 门控（`xy_valid && v_xy_valid` = `!_deadreckon_time_exceeded && !_using_synthetic_position`）在持续 vision 输入下满足；`velPosAiding = gps || ev_pos || ev_vel`（ekf_helper.cpp:998）确认 ev_pos 计入辅助。
- **板端 SLAM 会 OOM**（fastlivo_mapping anon-rss 2.9GB，板子内存 3.5GB，被 oom-killer 杀过）——重启 SLAM 可恢复，但长期需调低内存（如增大 voxel 分辨率）。

## 后续约束
1. 先用 GPS/PX4 local position 验证成熟轨迹控制器，再恢复本视觉 EKF 实验。
2. 关注板端 SLAM 内存（OOM 风险）。

## 环境恢复速查（本机 ros1-rviz 容器）
```bash
docker exec ros1-rviz xhost +   # 必须，否则 gzclient 崩
docker exec ros1-rviz bash -c 'cd /root/PX4_Firmware/launch && source /root/catkin_ws/devel/setup.bash && \
  export ROS_PACKAGE_PATH=$ROS_PACKAGE_PATH:/root/PX4_Firmware:/root/PX4_Firmware/Tools/sitl_gazebo && \
  export GAZEBO_PLUGIN_PATH=$GAZEBO_PLUGIN_PATH:/root/PX4_Firmware/build/px4_sitl_default/build_gazebo && \
  export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0 && \
  export ROS_MASTER_URI=http://192.168.0.2:11311 && export PX4_SIM_MODEL=iris && \
  nohup roslaunch px4 outdoor_my.launch gui:=true > /tmp/sim_gui.log 2>&1 &'
# 板端：
ssh root@192.168.0.2 'docker start ros1_dev && docker exec -d ros1_dev bash -c "source /opt/ros/noetic/setup.bash && roscore"'
ssh root@192.168.0.2 'docker exec ros1_dev bash -c "export ROS_MASTER_URI=http://192.168.0.2:11311; source /root/catkin_ws/devel/setup.bash 2>/dev/null; nohup roslaunch fast_livo mapping_avia_sim.launch rviz:=false > /tmp/slam_sim.log 2>&1 &"'
# 本机 republisher：
docker exec ros1-rviz bash -c 'source /root/catkin_ws/devel/setup.bash && export ROS_MASTER_URI=http://192.168.0.2:11311 && setsid nohup python3 /root/fastlio_odom_republisher.py > /tmp/repub.log 2>&1 < /dev/null &'
```
