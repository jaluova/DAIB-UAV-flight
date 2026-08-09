# openEuler 24.03 + ROS1 Noetic + FAST-LIVO2 部署总结

## 环境

| 项目 | 详情 |
|------|------|
| 硬件 | Atlas 200I DK A2 (ARM aarch64, 4核, 3.4G 内存) |
| 系统 | openEuler 24.03 LTS |
| 容器 | `ros1_dev` (Docker, 基于 `openeuler/openeuler:24.03-lts-sp4`) |
| ROS | Noetic 1.16.0 |
| GCC | 12.3.1 |
| Python | 3.11.6 |
| CMake | 3.27.9 |
| OpenCV | 4.5.2 |
| Eigen | 3.3.8 |
| PCL | 1.12.1 |
| Boost | 1.83.0 |
| 工作空间 | `~/catkin_ws` (devel 在容器内, build 每次清理) |

## 最短路径（一键脚本）

```bash
# ============================================
# 0. ROS Noetic 安装
# ============================================
bash -c 'cat > /etc/yum.repos.d/ROS.repo << EOF
[openEulerROS-Noetic]
name=openEulerROS-Noetic
baseurl=https://eulermaker.compass-ci.openeuler.openatom.cn/api/ems1/repositories/ROS-SIG-Multi-Version_ros-noetic_openEuler-24.03-LTS-TEST1/openEuler%3A24.03-LTS/aarch64/
enabled=1
gpgcheck=0
EOF'

dnf install -y "ros-noetic-*" --skip-broken
dnf install -y eigen3-devel opencv pcl-devel boost-devel git cmake

# ============================================
# 1. Sophus
# ============================================
cd /tmp
git clone https://github.com/strasdat/Sophus.git
cd Sophus
git checkout a621ff
sed -i 's/unit_complex_.real() = 1.;/unit_complex_.real(1.);/' sophus/so2.cpp
sed -i 's/unit_complex_.imag() = 0.;/unit_complex_.imag(0.);/' sophus/so2.cpp
mkdir build && cd build
cmake .. && make -j4 && make install

# ============================================
# 2. 克隆源码
# ============================================
mkdir -p ~/catkin_ws/src
cd ~/catkin_ws/src
git clone https://github.com/xuankuzcr/rpg_vikit.git
git clone https://github.com/hku-mars/FAST-LIVO2.git

# ============================================
# 3. 源码修复
# ============================================
# 3a. vikit 里 OpenCV 旧 API
sed -i 's/CV_RANSAC/cv::RANSAC/'       rpg_vikit/vikit_common/src/homography.cpp
sed -i 's/CV_INTER_LINEAR/cv::INTER_LINEAR/' rpg_vikit/vikit_common/src/pinhole_camera.cpp
sed -i 's/CV_WINDOW_AUTOSIZE/cv::WINDOW_AUTOSIZE/' rpg_vikit/vikit_common/src/img_align.cpp

# 3b. FAST-LIVO2 和 vikit 补 Sophus 链接路径
# 注意：必须用 printf 保证换行，echo >> 可能粘到上一行
printf '\nset(Sophus_LIBRARIES "/usr/local/lib/libSophus.so")\n' >> FAST-LIVO2/CMakeLists.txt
printf '\nset(Sophus_LIBRARIES "/usr/local/lib/libSophus.so")\n' >> rpg_vikit/vikit_common/CMakeLists.txt

# ============================================
# 4. 解决 openEuler 的 catkin 问题
# ============================================

# 4a. openEuler 缺 catkin_find_pkg 可执行文件，手动创建
cat > /opt/ros/noetic/bin/catkin_find_pkg << 'EOF'
#!/bin/bash
source /opt/ros/noetic/setup.bash &>/dev/null
catkin_find --without-underlays --libexec --share "$@"
EOF
chmod +x /opt/ros/noetic/bin/catkin_find_pkg

# 4b. openEuler 的 catkin toplevel.cmake 有兼容问题，手写 CMakeLists.txt
cat > ~/catkin_ws/src/CMakeLists.txt << 'EOF'
cmake_minimum_required(VERSION 3.0.2)
project(Workspace)
set(CATKIN_TOPLEVEL TRUE)
set(catkin_EXTRAS_DIR "/opt/ros/noetic/share/catkin/cmake")
include("${catkin_EXTRAS_DIR}/all.cmake" NO_POLICY_SCOPE)
EOF

# 4c. Sophus 库路径加入 ld 搜索
echo "/usr/local/lib" > /etc/ld.so.conf.d/sophus.conf
ldconfig

# ============================================
# 5. 编译（跳过 livox_ros_driver node, 消息手动装）
# ============================================
source /opt/ros/noetic/setup.bash
cd ~/catkin_ws
# 跳过 livox_ros_driver 编译：openEuler catkin 不创建 _generate_messages_cpp target
touch ~/catkin_ws/src/livox_ros_driver/livox_ros_driver/CATKIN_IGNORE
catkin_make -j2

# test 链接那一步会失败（Sophus undefined reference），
# 不影响主程序，单独编一次最终目标即可：
cd build && make -j2 fastlivo_mapping

# ============================================
# 6. livox_ros_driver 消息类型手动安装
# ============================================
# openEuler 的 catkin 0.8.10 无法自动生成消息头，需手动生成。

# C++ 头文件 — CustomPoint.h 手写精简版，CustomMsg.h 用 FAST-LIVO2 自带的
MSG_SRC=~/catkin_ws/src/livox_ros_driver/livox_ros_driver/msg
mkdir -p ~/catkin_ws/devel/include/livox_ros_driver
cp ~/catkin_ws/src/FAST-LIVO2/include/livox_ros_driver/CustomMsg.h \
   ~/catkin_ws/devel/include/livox_ros_driver/

# 手写 CustomPoint.h（见 repo 完整版）
cat > ~/catkin_ws/devel/include/livox_ros_driver/CustomPoint.h << 'CPPEOF'
#ifndef LIVOX_ROS_DRIVER_MESSAGE_CUSTOMPOINT_H
...
#endif
CPPEOF

# Python 消息 — 用 genpy 手动生成
mkdir -p ~/catkin_ws/devel/lib/python3.11/site-packages/livox_ros_driver/msg
PY_OUT=~/catkin_ws/devel/lib/python3.11/site-packages/livox_ros_driver
/opt/ros/noetic/lib/genpy/genmsg_py.py $MSG_SRC/CustomPoint.msg \
  -p livox_ros_driver -o $PY_OUT/msg/ -I livox_ros_driver:$MSG_SRC
/opt/ros/noetic/lib/genpy/genmsg_py.py $MSG_SRC/CustomMsg.msg \
  -p livox_ros_driver -o $PY_OUT/msg/ \
  -I livox_ros_driver:$MSG_SRC \
  -I std_msgs:/opt/ros/noetic/share/std_msgs/msg

# __init__.py
echo 'from .msg import *' > $PY_OUT/__init__.py
echo 'from ._CustomMsg import *' > $PY_OUT/msg/__init__.py
echo 'from ._CustomPoint import *' >> $PY_OUT/msg/__init__.py
```

## 实际问题记录（8 个坑，6 个是 openEuler 特有的）

### 1. Sophus 版本 & GCC 12 编译错误（通用）

**现象**：`lvalue required as left operand`、`undefined reference to Sophus::SE3`

**修复**：`git checkout a621ff`，并修复 `so2.cpp` 的 `.real() = 1.` 写法为 `.real(1.)`。

### 2. vikit 的 OpenCV 4 API 不兼容（通用）

**现象**：`CV_RANSAC`、`CV_INTER_LINEAR` 等未定义

**修复**：全局替换为 `cv::RANSAC`、`cv::INTER_LINEAR`、`cv::WINDOW_AUTOSIZE`。

### 3. Sophus 链接失败（通用，ARM 更常见）

**现象**：`libvikit_common.so: undefined reference to Sophus::SE3::*`，尽管 Sophus 已 `make install`

**修复**：在 FAST-LIVO2 和 vikit_common 的 `CMakeLists.txt` 中显式指定：
```cmake
set(Sophus_LIBRARIES "/usr/local/lib/libSophus.so")
```

### 4. openEuler 缺 `catkin_find_pkg` 可执行文件

**现象**：`catkin_make` 报 `Search for 'catkin' in workspace failed`

**根因**：openEuler 的 `ros-noetic-catkin` 包只提供了 shell 函数版，没有 `/opt/ros/noetic/bin/catkin_find_pkg` 脚本。cmake 的 `execute_process` 只能调用可执行文件，调用不到 shell 函数。

**修复**：手动创建包装脚本（见最短路径步骤 4a）。

### 5. openEuler 的 catkin workspace CMake 初始化失败

**现象**：`include could not find requested file: /root/catkin_ws/src//root/catkin_ws/src/cmake/all.cmake`

**根因**：`catkin_find_pkg` 的返回值在 cmake 中拼接异常，加上 openEuler catkin 的 `toplevel.cmake` 对 workspace 内搜索 catkin 的逻辑不完全兼容。

**修复**：跳过 toplevel.cmake，手写 workspace CMakeLists.txt（见最短路径步骤 4b）。

### 6. Sophus 运行时链接失败

**现象**：`fastlivo_mapping: error while loading shared libraries: libSophus.so`

**修复**：`/usr/local/lib` 不在容器默认搜索路径，加 `ld.so.conf`：
```bash
echo "/usr/local/lib" > /etc/ld.so.conf.d/sophus.conf && ldconfig
```

### 7. openEuler catkin 不创建 `_generate_messages_cpp` target

**现象**：
```
CMake Error at .../CMakeLists.txt:154 (add_dependencies):
  The dependency target "livox_ros_driver_generate_messages_cpp" of target
  "livox_ros_driver_node" does not exist.
```

**根因**：openEuler 的 `ros-noetic-catkin` (0.8.10) 的 `generate_messages()` 宏与标准 ROS 行为不一致，不创建 `_generate_messages_cpp`、`_gencpp`、`_EXPORTED_TARGETS` 等 target。

网上通用方案 (改用 `_gencpp` / `_EXPORTED_TARGETS`) 在 openEuler 上均无效。

**修复**：
1. `CATKIN_IGNORE` 跳过 `livox_ros_driver` 的编译（我们只需要消息定义，不需要驱动节点）
2. 使用 FAST-LIVO2 自带的 `CustomMsg.h` + 手写 `CustomPoint.h` 提供 C++ 消息头
3. 使用 `genpy` 手动生成 Python 消息模块

详见最短路径步骤 6。

### 8. Livox SDK 在 GCC 12 上编译失败

**现象**：
```
error: 'shared_ptr' in namespace 'std' does not name a template type
error: 'make_shared' is not a member of 'std'
```

**根因**：Livox-SDK 的 `thread_base.h/cpp` 使用了 `std::shared_ptr` 但缺 `#include <memory>`，GCC 12 不再隐式包含此头文件。

**修复**：
```bash
SDK_DIR=/path/to/Livox-SDK
sed -i '/#include "noncopyable.h"/a #include <memory>' $SDK_DIR/sdk_core/src/base/thread_base.h
sed -i '/#include "thread_base.h"/a #include <memory>' $SDK_DIR/sdk_core/src/base/thread_base.cpp
```
推荐先全局安装 Livox-SDK（带补丁），避免 catkin 每次自动克隆时覆盖补丁。

## 测试数据

`/data/Retail_Street.bag` (1.9G, 2:15s)：

| Topic | 类型 | 消息数 |
|-------|------|--------|
| `/livox/lidar` | `livox_ros_driver/CustomMsg` | 1355 |
| `/livox/imu` | `sensor_msgs/Imu` | 27447 |
| `/left_camera/image` | `sensor_msgs/Image` | 1355 |

## 运行

```bash
# 终端 1: roscore
source /opt/ros/noetic/setup.bash
source ~/catkin_ws/devel/setup.bash
roscore

# 终端 2: FAST-LIVO2（无 rviz）
source /opt/ros/noetic/setup.bash
source ~/catkin_ws/devel/setup.bash
roslaunch fast_livo mapping_avia.launch rviz:=false

# 终端 3: 播放 bag（注意 --clock 用系统时间 / --pause 先在 paused 状态）
source /opt/ros/noetic/setup.bash
source ~/catkin_ws/devel/setup.bash
rosbag play /data/Retail_Street.bag --clock
```

加载完配置后等待传感器数据 — LiDAR (`/livox/lidar`)、IMU (`/livox/imu`)、相机 (`/left_camera/image`)。播放 bag 即可触发定位建图。

## 参考

- FAST-LIVO2 仓库: https://github.com/hku-mars/FAST-LIVO2
- 资源受限平台论文: https://arxiv.org/pdf/2501.13876
- Sophus: https://github.com/strasdat/Sophus
- rpg_vikit (FAST-LIVO2 分支): https://github.com/xuankuzcr/rpg_vikit
- openEuler ROS 安装指南: https://openeuler-ros-docs.readthedocs.io/en/latest/installation/install-ros-noetic.html
