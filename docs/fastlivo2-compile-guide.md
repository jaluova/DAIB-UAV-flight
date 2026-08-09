# FAST-LIVO2 在 Atlas 200I DK A2 上编译踩坑指南

## 环境背景

| 项目 | 详情 |
|------|------|
| 开发板 | Atlas 200I DK A2 (ARM aarch64, 4 核) |
| 操作系统 | openEuler 24.03 LTS |
| ROS | Noetic (ROS1) |
| 内存 | 3.4 GiB |
| NPU | Ascend 310B4 |
| GCC | 10.3.1 |
| Python | 3.9.9 |
| CMake | 3.22.0 |

## 预处理：ROS Noetic 安装

openEuler 24.03 的 Noetic 源是 TEST1 版本（未正式发版），部分包缺依赖。必须带 `--skip-broken` 安装：

```bash
# 1. 配源（ARM 架构）
bash -c 'cat > /etc/yum.repos.d/ROS.repo << EOF
[openEulerROS-Noetic]
name=openEulerROS-Noetic
baseurl=https://eulermaker.compass-ci.openeuler.openatom.cn/api/ems1/repositories/ROS-SIG-Multi-Version_ros-noetic_openEuler-24.03-LTS-TEST1/openEuler%3A24.03-LTS/aarch64/
enabled=1
gpgcheck=0
EOF'

# 2. 安装（跳过缺依赖的包）
dnf install "ros-noetic-*" --skip-broken

# 3. 补装系统级基础库
dnf install eigen3-devel opencv-devel pcl-devel boost-devel
```

> **注意**：部分包（rviz、turtlebot3、rosbridge、roslisp、moveit 等）因依赖未补齐会被自动跳过。如果后续编译发现缺了关键的 catkin 层包（如 cv-bridge、pcl-ros、tf 等），需要手动逐个 `dnf install ros-noetic-<包名>` 尝试。

---

## 依赖全景

FAST-LIVO2 依赖分成三层：

### 第一层：ROS Noetic + catkin 生态
- `ros-noetic-desktop-full` 或等价包（`--skip-broken` 已装）
- 关键 catkin 包：tf, image_transport, cv_bridge, pcl_ros, roscpp

### 第二层：独立 C++ 库（含版本地雷）

| 库 | 最低版本 | 备注 |
|----|----------|------|
| Eigen | ≥ 3.3.4 | 大量使用 `Eigen::Map`、块操作 |
| PCL | ≥ 1.8 | VoxelGrid、PointXYZI/PointXYZRGB |
| OpenCV | ≥ 4.2 | 不可用 3.x，`cv::NORM_HAMMING2` 等 API 不兼容 |
| Sophus | `a621ff` 精确提交 | **版本地雷 1** |
| Boost | 任意版本 | `libboost-dev libboost-thread-dev` |

### 第三层：需手动克隆入 catkin 工作空间

| 包 | 仓库 | 备注 |
|----|------|------|
| rpg_vikit | `xuankuzcr/rpg_vikit` | **版本地雷 2**，不能用 uzh-rpg 原版 |
| FAST-LIVO2 | `hku-mars/FAST-LIVO2` | 主体 |
| livox_ros_driver | Livox 官方 | 仅当用 Livox 雷达时需要；用标准机械雷达可省略 |

---

## 坑位清单

### 坑 1：Sophus 版本不兼容（必踩）

**症状**：
```
error: 'class Sophus::SO3d' has no member named '...'
fatal error: sophus/so3.h: No such file or directory
undefined reference to `Sophus::SE3::exp(...)'
```

**根因**：Sophus 在 `a621ff` 之后改成了模板化 API（`Sophus::SE3<T>`），FAST-LIVO2 用非模板版（`Sophus::SO3d`、`Sophus::SE3d`）。

**修复**：
```bash
git clone https://github.com/strasdat/Sophus.git
cd Sophus
git checkout a621ff          # ← 必须精确切到这个 commit
mkdir build && cd build
cmake .. && make -j4
sudo make install
```

---

### 坑 2：Sophus `so2.cpp` 编译错误（ARM 特化）

**症状**：
```
so2.cpp:32:26: error: lvalue required as left operand of assignment
  unit_complex_.real() = 1.;
  unit_complex_.imag() = 0.;
```

**根因**：`a621ff` 里的古早写法在 GCC 10+ 上不合法。

**修复** — 编译 Sophus 前改 `so2.cpp`：
```cpp
// 原代码（第 32-33 行）
unit_complex_.real() = 1.;    // ❌
unit_complex_.imag() = 0.;    // ❌

// 改为
unit_complex_.real(1.);       // ✅
unit_complex_.imag(0.);       // ✅
```

---

### 坑 3：rpg_vikit 用错仓库

**症状**：
```
fatal error: vikit/abstract_camera.h: No such file or directory
```

**根因**：FAST-LIVO1 用 `uzh-rpg/rpg_vikit`，FAST-LIVO2 用 `xuankuzcr/rpg_vikit`（郑纯然的 fork），头文件和函数签名不同。

**修复**：
```bash
cd ~/catkin_ws/src
git clone https://github.com/xuankuzcr/rpg_vikit.git
# 不是 git clone https://github.com/uzh-rpg/rpg_vikit.git ！
```

---

### 坑 4：vikit 里的 OpenCV 旧 API

**症状**：
```
error: 'CV_RANSAC' was not declared in this scope
error: 'CV_INTER_LINEAR' was not declared in this scope
error: 'CV_WINDOW_AUTOSIZE' was not declared in this scope
```

**根因**：vikit 源代码用了 OpenCV 3.x 的 C 风格常量，OpenCV 4.x 已改为 `cv::` 命名空间。

**修复** — 改三个文件：

`rpg_vikit/vikit_common/src/homography.cpp` (第 48 行):
```cpp
// CV_RANSAC   →   cv::RANSAC
```

`rpg_vikit/vikit_common/src/pinhole_camera.cpp` (第 112 行):
```cpp
// CV_INTER_LINEAR  →  cv::INTER_LINEAR
```

`rpg_vikit/vikit_common/src/img_align.cpp` (第 237、437 行):
```cpp
// CV_WINDOW_AUTOSIZE  →  cv::WINDOW_AUTOSIZE
```

---

### 坑 5：栈上大数组导致 crash

**症状**：
```
[laserMapping-1] process has died [pid xxxx, exit code -11, ...]
```
跑自己的数据时初始化不久就崩溃。

**根因**：`lidar_selection.cpp` 第 ~376 行在栈上分配图像大小的数组，大分辨率图片直接栈溢出。

**修复** — `FAST-LIVO2/src/lidar_selection.cpp`:
```cpp
// float it[height * width] = {0.0};      // ❌ 栈分配
std::vector<float> it(height * width, 0);  // ✅ 堆分配
```

你的板子只有 3.4G 内存，这个问题会特别严重。

---

### 坑 6：ARM64 上 Sophus 链接失败

**症状**：
```
/usr/bin/ld: .../libvikit_common.so: undefined reference to `Sophus::SE3::exp(...)'
```
（明明已经 `sudo make install` 了 Sophus）

**根因**：ARM64 上 `libSophus.so` 安装到 `/usr/local/lib/`，但 catkin_make 的 CMake 默认搜索可能跳过。

**修复** — 在 `FAST-LIVO2/CMakeLists.txt` 和 `rpg_vikit/vikit_common/CMakeLists.txt` 中加：
```cmake
set(Sophus_LIBRARIES "/usr/local/lib/libSophus.so")
```

---

### 坑 7：内存不足导致编译失败

**症状**：`make -j4` 跑着跑着 OOM 杀掉进程。

**根因**：3.4G 内存 + PCL/Eigen 模板展开 + GCC 并行编译 → 内存峰值爆炸。

**修复**：
```bash
# 单线程编译，减少内存峰值
catkin_make -j1

# 或者限制并行数
catkin_make -j2

# 如果还是 OOM，先关掉 ros2_dev 容器腾内存
docker stop ros2_dev
```

---

### 坑 8：openEuler 缺 catkin 层依赖（平台特化）

**症状**：
```
Could not find a package configuration file provided by "cv_bridge"
Could not find a package configuration file provided by "pcl_ros"
Could not find a package configuration file provided by "image_transport"
```

**根因**：`--skip-broken` 可能跳过了这些关键 ROS 包，导致 catkin_make 找不到。

**修复**：
```bash
# 逐个尝试安装
dnf install ros-noetic-cv-bridge ros-noetic-pcl-ros ros-noetic-image-transport ros-noetic-tf ros-noetic-roscpp
# 如果 yum 里没有，可能需要从源码自己编这些包
```

---

### 坑 9：openEuler catkin 不创建 `_generate_messages_cpp` target

**症状**：
```
CMake Error at .../CMakeLists.txt:154 (add_dependencies):
  The dependency target "livox_ros_driver_generate_messages_cpp" of target
  "livox_ros_driver_node" does not exist.
```

同样的问题出现在 `_gencpp`、`_EXPORTED_TARGETS` 等 target — 在 openEuler 上均无效。

**根因**：openEuler 的 `ros-noetic-catkin` (0.8.10) `generate_messages()` 宏行为与标准 ROS 不一致。

**修复**：CATKIN_IGNORE 跳过该包编译，手动生成消息定义。
详见 `fastlivo2-openeuler-summary.md` 步骤 6。

---

### 坑 10：Livox SDK 在 GCC 12 上编译失败

**症状**：
```
error: 'shared_ptr' in namespace 'std' does not name a template type
error: 'make_shared' is not a member of 'std'
```

**根因**：Livox-SDK 的 `thread_base.h/cpp` 缺 `#include <memory>`，GCC 12 不再隐式包含。

**修复**：
```bash
sed -i '/#include "noncopyable.h"/a #include <memory>' sdk_core/src/base/thread_base.h
sed -i '/#include "thread_base.h"/a #include <memory>' sdk_core/src/base/thread_base.cpp
```

推荐先全局 `make install` Livox-SDK（带补丁），避免 catkin 每次自动 clone 时覆盖补丁。

---

## 编译步骤（汇总）

```bash
# === 1. 创建 catkin 工作空间 ===
mkdir -p ~/catkin_ws/src

# === 2. 编译安装 Sophus ===
cd /tmp
git clone https://github.com/strasdat/Sophus.git
cd Sophus
git checkout a621ff
# 改 so2.cpp（见坑 2）
sed -i 's/unit_complex_.real() = 1.;/unit_complex_.real(1.);/' sophus/so2.cpp
sed -i 's/unit_complex_.imag() = 0.;/unit_complex_.imag(0.);/' sophus/so2.cpp
mkdir build && cd build
cmake .. && make -j4 && sudo make install

# === 3. 克隆 vikit、FAST-LIVO2、livox_ros_driver ===
cd ~/catkin_ws/src
git clone https://github.com/xuankuzcr/rpg_vikit.git
git clone https://github.com/hku-mars/FAST-LIVO2.git
git clone https://github.com/Livox-SDK/livox_ros_driver.git

# === 4. 改 vikit 的 OpenCV 旧 API ===
# 手动改了三个文件（见坑 4）

# === 5. 改 FAST-LIVO2 源码 ===
# - lidar_selection.cpp: 栈数组 → vector（见坑 5）
# - CMakeLists.txt: 补 Sophus 路径（见坑 6）

# === 6. livox_ros_driver: 跳过编译 + 手动装消息 ===
# openEuler catkin 不创建 _generate_messages_cpp target（见坑 7）
touch ~/catkin_ws/src/livox_ros_driver/livox_ros_driver/CATKIN_IGNORE
# 手动装消息定义（见 openEuler 总结文档步骤 6）

# === 7. 编译 ===
source /opt/ros/noetic/setup.bash
cd ~/catkin_ws
catkin_make -j2

# test 链接失败（Sophus undefined reference）不影响主程序
cd build && make -j2 fastlivo_mapping

# === 8. 安装 Livox SDK（GCC 12 补丁）+ 全局安装避免 catkin 自动克隆 ===
# 见坑 8
cd /tmp
git clone https://github.com/Livox-SDK/Livox-SDK.git
cd Livox-SDK
sed -i '/#include "noncopyable.h"/a #include <memory>' sdk_core/src/base/thread_base.h
sed -i '/#include "thread_base.h"/a #include <memory>' sdk_core/src/base/thread_base.cpp
mkdir build && cd build
cmake .. && make -j2 && make install && ldconfig

# === 9. source ===
echo "source ~/catkin_ws/devel/setup.bash" >> ~/.bashrc
```

---

## 性能参考

郑纯然团队在 **RK3588**（8 核 ARM, 4×A76+4×A55, 2.4GHz）上测试的前身版结果：

| 指标 | 原版 FAST-LIVO2 | 轻量版 (资源受限优化) |
|------|:--------------:|:-------------------:|
| 每帧运行时间 | baseline | **-33%** |
| 内存使用 | baseline | **-47%** |
| 精度 (RMSE) | baseline | +3cm |

Atlas 200I DK A2 是 **4 核 A55**（比 RK3588 的 A76 慢不少），预计需要：
- 关闭所有可视化输出（rviz 也装不上）
- 降低图像分辨率和 LiDAR 点云密度
- 启用资源受限论文中的优化参数

实际能不能达到实时（10Hz LiDAR + 相机），需要跑起来再测。

---

## 参考资源

- FAST-LIVO2 仓库: https://github.com/hku-mars/FAST-LIVO2
- 资源受限平台论文: https://arxiv.org/pdf/2501.13876
- Sophus 仓库: https://github.com/strasdat/Sophus
- rpg_vikit (FAST-LIVO2 版本): https://github.com/xuankuzcr/rpg_vikit
- openEuler ROS 文档: https://openeuler-ros-docs.readthedocs.io/en/latest/installation/install-ros-noetic.html
- ARM 交叉编译讨论: https://github.com/hku-mars/FAST-LIVO2/issues/449
- Noetic 编译经验: https://github.com/hku-mars/FAST-LIVO/issues/53
