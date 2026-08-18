# Orange Pi 5 Max openEuler ARM64 containers

This directory builds two Linux ARM64 images for the Orange Pi 5 Max:

- `daib-algorithm:openeuler-arm64`: ROS master, FAST-LIVO2, EGO-Planner,
  DAIB-Explorer, Foxglove Bridge and offline bag playback support.
- `daib-drivers:openeuler-arm64`: D435i/librealsense and Livox MID-70 drivers.

Both images use `openeuler/openeuler:24.03-lts-sp4` with ROS Noetic. The Orange
Pi host currently uses Orange Pi Ubuntu 22.04.4 LTS ARM64; containers provide
their own openEuler 24.03 userspace and share the Ubuntu host's Rockchip kernel.
These images are CPU-only and do not include RK3588 GPU or NPU runtimes.

## Why openEuler 24.03

The available ROS Noetic RPM repository targets openEuler 24.03 ARM64. It is a
TEST repository and some optional RPMs are incomplete, so the image installs an
explicit dependency set derived from the algorithm and driver package manifests
instead of the entire repository. The repository's `python3-catkin_pkg` package
prefixes its commands with `python3-`; the install script adds the standard
catkin command names expected by upstream catkin. ROS master startup and catkin
C++/Python message generation have been validated in the ARM64 base container.

`ddynamic_reconfigure`, required by the ROS 1 RealSense wrapper, is not present
in the openEuler repository and is built from a pinned source tag in the driver
workspace.

## 1. Prepare a clean source archive

From the repository root:

```bash
./deploy/scripts/package-build-context.sh
```

The archive excludes bags, backups, Git metadata, simulation assets, logs and
generated files. Documentation remains excluded from the Docker build context.

## 2. Configure the build proxy on the Mac

The local HTTP proxy is listening on port 7897. Docker Desktop must use it for
base-image pulls. The validated setup enables the macOS HTTP and HTTPS system
proxies at `http://127.0.0.1:7897`; Docker Desktop then exposes its internal
daemon proxy as `http.docker.internal:3128`. A shell-level `https_proxy` alone
does not configure the Docker daemon.

The build script also passes the proxy to DNF, Git and other build steps:

```bash
export DAIB_BUILD_PROXY=http://host.docker.internal:7897
```

Do not use `127.0.0.1:7897` inside a build container because that address points
back to the container, not the Mac.

## 3. Build on an Apple Silicon Mac

Start Docker Desktop, then run:

```bash
BUILD_JOBS=1 ./deploy/scripts/build-openeuler-arm64-images.sh
```

The output is `dist/daib-openeuler-arm64-images.tar.gz` plus its SHA-256 file.
The build is native `linux/arm64`, but compiling PCL, ROS packages and sensor
drivers still takes a long time. Keep `BUILD_JOBS=1` for an 8 GiB Orange Pi and
for a Docker Desktop VM with about 4 GiB RAM.

When only the algorithm image changed, build and package it without rebuilding
the driver image:

```bash
BUILD_JOBS=1 ./deploy/scripts/build-algorithm-image.sh
```

This creates `dist/daib-algorithm-openeuler-arm64.tar.zst` and its SHA-256
file. Docker can load that archive directly with `docker load -i`.

## 4. Prepare the Orange Pi 5 Max

The checked host is Orange Pi Ubuntu 22.04.4 LTS (`jammy`) on ARM64. Verify the
board before transferring images:

```bash
uname -m
docker version
docker compose version || docker-compose --version
free -h
df -h
ip -br link
lsusb
```

`uname -m` must report `aarch64` or `arm64`. Use at least 8 GiB RAM and keep at
least 40 GiB of free storage; NVMe storage is strongly recommended. If Docker is
not installed, use Docker's official Ubuntu installation instructions and
install the Engine, Buildx and Compose plugin before continuing.

The checked board has 7.7 GiB RAM, 3.9 GiB swap, and a 117 GiB NVMe mounted at
`/mnt/ssd` with about 93 GiB currently free. Store both Docker data and runtime
data on that NVMe. After moving Docker's `data-root`, verify that the NVMe is
mounted before Docker starts:

```bash
findmnt /mnt/ssd
docker info --format '{{.DockerRootDir}}'
systemctl show docker -p After -p RequiresMountsFor
```

The expected Docker root is `/mnt/ssd/docker`. The mount must be persistent in
`/etc/fstab`; otherwise Docker can write to the underlying SD-card directory
when the NVMe is unavailable during boot.

## 5. Load on the Orange Pi 5 Max

Transfer the image archive, this `deploy` directory and a configured `.env`:

```bash
gzip -dc daib-openeuler-arm64-images.tar.gz | docker load
cp deploy/.env.example deploy/.env
ip -br link
```

When only the algorithm image changed, transfer the smaller standalone archive.
`rsync --partial` can resume an interrupted transfer:

```bash
rsync -ahP \
  dist/daib-algorithm-openeuler-arm64.tar.zst \
  orangepi@192.168.218.200:/mnt/ssd/
```

On the board, verify and load it directly. Docker recognizes the zstd
compression, so it does not need to be decompressed first:

```bash
cd /mnt/ssd
sha256sum daib-algorithm-openeuler-arm64.tar.zst
docker load -i daib-algorithm-openeuler-arm64.tar.zst
docker image inspect daib-algorithm:openeuler-arm64 \
  --format 'ID={{.Id}} ARCH={{.Architecture}} SIZE={{.Size}}'
```

The artifact built and validated on 2026-08-08 has SHA-256:

```text
fdcd20c45267181e6f600b5e05dd22b836c2b249ec9e047d6b17c44a55810a31
```

`docker load` reuses content-addressed layers already present on the board, but
the standalone archive produced by `docker save` still contains and transfers
the complete image. For frequent updates, use a registry so `docker pull`
transfers only missing layers. After a successful load and startup check, the
archive in `/mnt/ssd` may be removed. Inspect old untagged images before
reclaiming their storage:

```bash
docker image ls --filter dangling=true
```

### Frequent updates through the LAN registry

The validated Mac-side registry runs at `192.168.218.119:5050`. Port 5000 is
not used because macOS ControlCenter/AirPlay already listens there. The registry
uses the persistent Docker volume `daib-registry-data` and does not need Internet
access after the `registry:2` image has been downloaded once:

```bash
docker volume create daib-registry-data
docker run -d \
  --name daib-registry \
  --restart unless-stopped \
  -p 5050:5000 \
  -v daib-registry-data:/var/lib/registry \
  registry:2

curl http://127.0.0.1:5050/v2/
curl http://192.168.218.119:5050/v2/
```

Both curl commands must return `{}`. Build the algorithm image, tag it for the
local registry and push it:

```bash
BUILD_JOBS=1 ./deploy/scripts/build-algorithm-image.sh
docker tag \
  daib-algorithm:openeuler-arm64 \
  localhost:5050/daib-algorithm:openeuler-arm64
docker push localhost:5050/daib-algorithm:openeuler-arm64
```

The initial push stores every layer. Later pushes and pulls transfer only layers
whose content digest changed. The registry state can be checked without pulling
an image:

```bash
curl http://127.0.0.1:5050/v2/_catalog
curl http://127.0.0.1:5050/v2/daib-algorithm/tags/list
docker ps --filter name=daib-registry
```

The registry uses plain HTTP on a trusted LAN. Merge the following entry into
the board's existing `/etc/docker/daemon.json`; do not overwrite other settings
such as `data-root`:

```json
{
  "insecure-registries": [
    "192.168.218.119:5050"
  ]
}
```

Restart Docker on the board, pull the image and select it in `deploy/.env`:

```bash
sudo systemctl restart docker
curl http://192.168.218.119:5050/v2/
docker pull 192.168.218.119:5050/daib-algorithm:openeuler-arm64
```

```dotenv
ALGORITHM_IMAGE=192.168.218.119:5050/daib-algorithm:openeuler-arm64
```

Then recreate only the algorithm service:

```bash
docker compose --env-file deploy/.env \
  -f deploy/compose.orange-pi-5-max.yml \
  up -d --no-build --no-deps --force-recreate algorithm
```

Reserve `192.168.218.119` for the Mac in DHCP or replace it consistently if the
address changes. Docker Desktop and the `daib-registry` container must be running
while the board pulls. Board-side pull and algorithm-only Compose recreation were
validated on 2026-08-10 with the `yyy-openeuler-arm64` tag.

The checked board defaults are `DATA_DIR=/mnt/ssd/data`,
`LIDAR_INTERFACE=enP3p49s0`, `LIDAR_HOST_CIDR=192.168.1.50/24`, and
`LIDAR_DEVICE_IP=192.168.1.119`. Create the data directory before starting the
containers. The privileged driver uses host networking and configures the
dedicated LiDAR interface at startup. It also sets `rp_filter=0` for `all` and
the LiDAR interface; both settings are required for Livox limited-broadcast
reception on the validated Rockchip 6.1.43 kernel. Keep Wi-Fi on its existing
policy. Override these values only when the physical interface or LiDAR subnet
changes.

The validated MID-70 broadcast code is passed as
`bd_list:=3GGDLA4001V3191`. The entrypoint refuses to start Livox unless the
wired address, route to `192.168.1.119`, source address, and reverse-path filter
state all match the configured values. This prevents a healthy ROS process with
no point-cloud stream from being mistaken for a successful deployment.

To validate only the host-side LiDAR network without starting ROS drivers, run
the driver image with the normal LiDAR environment plus
`LIDAR_NETWORK_PREFLIGHT_ONLY=true`. The entrypoint configures and verifies the
network, prints `LiDAR network preflight passed`, and exits.

Start the containers:

```bash
docker compose --env-file deploy/.env -f deploy/compose.orange-pi-5-max.yml up -d --no-build
docker compose --env-file deploy/.env -f deploy/compose.orange-pi-5-max.yml logs -f
```

For real sensors, the repository-level startup scripts are the preferred entry
points. Run one of these on the Orange Pi host after connecting the D435i and
MID-70:

```bash
# LIO only: MID-70 + D435i IMU, camera disabled in FAST-LIVO.
./scripts/start_lio_only.sh --check-seconds 15

# Normal LIVO: MID-70 + D435i IMU + color image.
./scripts/start_livo.sh --check-seconds 15

# Normal LIVO plus a low-latency camera-only Foxglove stream.
./scripts/start_flight_stack.sh --check-seconds 15 --camera-rate 6
```

These scripts validate the Compose configuration, keep the persistent ROS
Master, reuse a healthy driver container, and automatically recreate drivers if
the container cannot see the configured LiDAR interface or route. They check
the LiDAR, IMU and (in LIVO mode) image rates and timestamp alignment. A
successful run ends with `[PASS] LIO-only stack is ready`.

For flight preparation, use the camera-first wrapper instead. It runs the same
sensor checks, then replaces the default all-topic Foxglove Bridge with a
camera-only, low-latency stream. The default is a 6 Hz raw image stream with a
4 MB send buffer so congestion drops frames instead of accumulating latency:

```bash
./scripts/start_flight_stack.sh
```

Runtime controls are available without editing the script:

```bash
./scripts/start_flight_stack.sh \
  --check-seconds 15 \
  --camera-rate 6 \
  --port 8765
```

The Foxglove image topic is
`/camera/color/image_fast_livo_foxglove`. FAST-LIVO continues to consume the
unmodified local `/camera/color/image_fast_livo` stream; only the remote
Foxglove copy is rate-limited.

To run LIO without the camera pipeline, use:

```bash
./scripts/start_lio_only.sh
```

This mode recreates the algorithm container with `use_camera:=false`, mounts
the repository calibration file read-only, and enables only the D435i
gyroscope/accelerometer plus the MID-70. ROS Master runs in the persistent
`roscore` service, so recreating the algorithm container does not invalidate
the running driver nodes. The script reuses a healthy, registered driver
container and validates LiDAR/IMU rates and synchronization. Foxglove remains
enabled for LIO outputs; disable it with `LIO_ENABLE_FOXGLOVE=false`.

After that check passes, record the three FAST-LIVO input topics with:

```bash
./scripts/record_fast_livo_inputs.sh
```

The default recording keeps FAST-LIVO's approximately 10 Hz image stream. To
inspect a near-real-time camera view later on a computer, include the raw
approximately 30 Hz image as well:

```bash
./scripts/record_fast_livo_inputs.sh --min-free-gb 20 --include-raw-image
```

This increases bag size substantially. In Foxglove playback, select
`/camera/color/image_raw` for the high-rate view; the algorithm input remains
`/camera/color/image_fast_livo`.

The recorder discovers the host directory mounted at `/bags` and writes to
`BAGS_DIR/fast_livo_real/<timestamp>/`. The result is immediately available to
the Compose bag-playback configuration. It uses LZ4 compression, splits at
4 GiB, stops cleanly on `Ctrl+C`, and stops before free space falls below 10
GiB. Duration and space limits are configurable:

```bash
./scripts/record_fast_livo_inputs.sh --max-minutes 5 --min-free-gb 15
```

Set `DAIB_ENV_FILE` or `DAIB_COMPOSE_FILE` only when the runtime files are in a
non-default location. Both scripts are Orange Pi host tools and intentionally
refuse to run on macOS.

Foxglove Bridge listens on all interfaces at port 8765 by default. Connect
Foxglove Desktop with `ws://<orange-pi-ip>:8765`. FAST-LIVO publishes its map
and registered clouds in `camera_init`, so use `camera_init` as the 3D panel's
fixed frame.

### Flight startup shortcuts

Run these commands on the Orange Pi host from `/mnt/huawei_ssd/daib`:

```bash
# LiDAR + D435i IMU only; camera is not used by FAST-LIVO.
./scripts/start_lio_only.sh --check-seconds 15

# Normal LIVO; D435i color/depth images participate in FAST-LIVO.
./scripts/start_livo.sh --check-seconds 15

# Normal LIVO plus a camera-only, low-latency Foxglove stream.
./scripts/start_flight_stack.sh --check-seconds 15 --camera-rate 6

# Stop Compose algorithm/drivers/roscore and legacy standalone containers.
./scripts/stop_daib_stack.sh
```

All startup scripts validate the sensor streams and perform a best-effort
clock check before starting ROS. The board has no usable hardware RTC; if NTP
is unavailable, the scripts restore the last known-good clock value when
possible and report a warning.

The startup scripts reuse a healthy `drivers` container by default and recreate
only the algorithm service. This keeps the RealSense USB/UVC session alive when
the algorithm is restarted. Use `--restart-drivers` only when a driver restart
is intentional or after changing the sensor mode.

The current flight shortcuts start localization/mapping only. They do not
start `DAIB-Explorer`, EGO-Planner, `daib_ego_bridge`, PX4/MAVROS offboard
control, autonomous exploration, or obstacle-avoidance control.

Replay the newest recorded bag session with the host helper. It stops the live
driver service before playback, keeps the persistent ROS Master, starts
FAST-LIVO and the all-topic Foxglove Bridge, and selects the newest session
below `BAGS_DIR/fast_livo_real`, including all split bag files in that session:

```bash
./scripts/start_bag_play.sh --rate 1.0
```

Pass an explicit host file, host directory, or `/bags` path as the final
argument when needed.
Use `--rate 0.5` only when deliberately inspecting the data in slow motion.
`--rate` controls playback only; recording always preserves the messages and
timestamps received in real time. The recorded image topic is FAST-LIVO's
nominal 10 Hz `/camera/color/image_fast_livo`, while the flight Foxglove stream
is an independent 6 Hz preview topic. When playback finishes, FAST-LIVO and
Foxglove remain available so the final map can still be inspected. Return to
live sensors with:

```bash
./scripts/start_flight_stack.sh --check-seconds 15 --camera-rate 6
```

The Compose file uses the current Compose specification. If the Compose plugin
is unavailable, install a compatible `docker-compose` binary and use:

```bash
docker-compose --env-file deploy/.env -f deploy/compose.orange-pi-5-max.yml up -d --no-build
```

## Runtime defaults

- FAST-LIVO2 starts in LIO-only mode without RViz.
- Foxglove Bridge starts on port 8765 and can describe Livox `CustomMsg`.
- `BAGS_DIR` is mounted read-only as `/bags`; no bag is replayed unless
  `BAG_FILE` is set.
- D435i publishes color, depth and fused IMU.
- librealsense defaults to its RSUSB backend so it does not depend on UVC patches in the Ubuntu host kernel.
- MID-70 publishes `livox_ros_driver/CustomMsg` at 10 Hz.
- Both containers share the host network and ROS master at `127.0.0.1:11311`.
- The driver container is privileged and mounts `/dev` for USB, V4L2, hidraw and Ethernet access.
- `DATA_DIR` is mounted into both containers as `/data` for runtime data.

The checked-in MID-70/D435i extrinsics are specific to the current physical
mounting. Recalibrate after changing the sensor mount. Hardware access, kernel
drivers and sensor timing must be validated on the Orange Pi 5 Max after loading
the images; a Mac build cannot verify them.

The implementation and validation history for the current images is recorded in
[`docs/orange-pi-5-max-container-worklog-20260809.md`](../docs/orange-pi-5-max-container-worklog-20260809.md).
