#!/usr/bin/env bash
set -Eeuo pipefail

ros_repo_url="${ROS_REPO_URL:-https://eulermaker.compass-ci.openeuler.openatom.cn/api/ems1/repositories/ROS-SIG-Multi-Version_ros-noetic_openEuler-24.03-LTS-TEST1/openEuler%3A24.03-LTS/aarch64/}"
poco_compat_url="${POCO_COMPAT_URL:-https://repo.openeuler.org/openEuler-24.03-LTS/everything/aarch64/Packages/poco-foundation-1.12.4-1.oe2403.aarch64.rpm}"
poco_compat_sha256="${POCO_COMPAT_SHA256:-dee6f06eb4b519c28558dbbe08b3d0cd7dbeff310707a9c8508c6a080c713e41}"
cat > /etc/yum.repos.d/ROS.repo <<EOF
[openEulerROS-Noetic]
name=openEulerROS-Noetic
baseurl=${ros_repo_url}
enabled=1
gpgcheck=0
EOF

dnf install -y \
  apr-devel \
  boost-devel \
  ca-certificates \
  cmake \
  cpio \
  diffutils \
  eigen3-devel \
  gcc \
  gcc-c++ \
  git \
  iproute \
  libcurl-devel \
  libusbx-devel \
  make \
  openssl-devel \
  opencv \
  patch \
  pcl-devel \
  pkgconf \
  python3-devel \
  systemd-devel \
  tar \
  unzip \
  usbutils \
  which

# Keep this list aligned with the algorithm and sensor-driver package.xml files.
# Installing ros-noetic-* also pulls unrelated desktop, navigation and debuginfo
# packages, increasing the installed size from about 1 GiB to about 6 GiB.
dnf install -y \
  ros-noetic-catkin \
  ros-noetic-cmake-modules \
  ros-noetic-cv-bridge \
  ros-noetic-diagnostic-updater \
  ros-noetic-dynamic-reconfigure \
  ros-noetic-eigen-conversions \
  ros-noetic-geometry-msgs \
  ros-noetic-image-transport \
  ros-noetic-message-filters \
  ros-noetic-message-generation \
  ros-noetic-message-runtime \
  ros-noetic-nav-msgs \
  ros-noetic-nodelet \
  ros-noetic-pcl-conversions \
  ros-noetic-pcl-ros \
  ros-noetic-rosbag \
  ros-noetic-roscpp \
  ros-noetic-roslaunch \
  ros-noetic-roslib \
  ros-noetic-rospy \
  ros-noetic-sensor-msgs \
  ros-noetic-std-msgs \
  ros-noetic-std-srvs \
  ros-noetic-tf \
  ros-noetic-tf2-ros \
  ros-noetic-visualization-msgs
test -f /opt/ros/noetic/setup.bash

# The TEST1 ROS packages were built against Poco 1.12.4 (SONAME 94), while
# openEuler 24.03 SP4 ships Poco 1.12.5p2 (SONAME 95). Keep the SP4 libraries
# and install the official older Foundation library alongside them for pcl_ros.
mkdir -p /tmp/poco-compat
curl -fL --retry 3 -o /tmp/poco-compat/poco-foundation.rpm \
  "${poco_compat_url}"
echo "${poco_compat_sha256}  /tmp/poco-compat/poco-foundation.rpm" | \
  sha256sum --check -
(
  cd /tmp/poco-compat
  rpm2cpio poco-foundation.rpm | cpio -id --quiet
)
install -m 0755 \
  /tmp/poco-compat/usr/lib64/libPocoFoundation.so.94 \
  /usr/local/lib/libPocoFoundation.so.94
echo '/usr/local/lib' > /etc/ld.so.conf.d/local-lib.conf
ldconfig
source /opt/ros/noetic/setup.bash
test -z "$(ldd /opt/ros/noetic/lib/libpcl_ros_filter.so | grep 'not found' || true)"
rm -rf /tmp/poco-compat

# openEuler prefixes catkin_pkg executables with python3-, while upstream
# catkin invokes their standard names (for example, catkin_find_pkg).
for command_path in /usr/bin/python3-catkin_*; do
  command_name="${command_path##*/python3-}"
  ln -sf "${command_path}" "/usr/local/bin/${command_name}"
done

command -v roscore >/dev/null
command -v catkin_make >/dev/null
command -v catkin_find_pkg >/dev/null
