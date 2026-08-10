# Orange Pi 5 Max openEuler ARM64 containers

This directory builds two Linux ARM64 images for the Orange Pi 5 Max:

- `daib-algorithm:openeuler-arm64`: ROS master, FAST-LIVO2, EGO-Planner,
  DAIB-Explorer, Foxglove Bridge and offline bag playback support.
- `daib-drivers:openeuler-arm64`: D435i/librealsense and Livox MID-70 drivers.

Both images use `openeuler/openeuler:24.03-lts-sp4` with ROS Noetic. The Orange
Pi host uses Arch Linux ARM64; containers provide their own openEuler 24.03
userspace and share the Arch host kernel. These images are CPU-only and do not
include RK3588 GPU or NPU runtimes.

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
file. Docker 29 can load that archive directly with `docker load -i`.

## 4. Prepare the Orange Pi 5 Max

The host must be a 64-bit Arch Linux installation. Verify the board before
transferring images:

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
not installed on Arch Linux, install and enable it with the distribution's
current `docker` and Compose packages before continuing.

The checked board has 7.8 GiB RAM, 11 GiB zram swap, and a 119 GiB NVMe mounted
at `/mnt/ssd`. Store both Docker data and runtime data on that NVMe. After moving
Docker's `data-root`, verify that the NVMe is mounted before Docker starts:

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

On the board, verify and load it directly. Docker 29 recognizes the zstd
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

The checked board defaults are `DATA_DIR=/mnt/ssd/data` and
`LIDAR_INTERFACE=enP3p49s0`. Create the data directory before starting the
containers. `LIDAR_HOST_CIDR=192.168.1.100/24` remains a placeholder until the
Livox is connected and its subnet is confirmed. Leave
`CONFIGURE_LIDAR_INTERFACE=false` until then; setting it to `true` changes the
host interface because the driver uses host networking.

Start the containers:

```bash
docker compose --env-file deploy/.env -f deploy/compose.orange-pi-5-max.yml up -d --no-build
docker compose --env-file deploy/.env -f deploy/compose.orange-pi-5-max.yml logs -f
```

For real sensors, the repository-level startup script is the preferred entry
point. Run it on the Orange Pi host after connecting the D435i and MID-70:

```bash
./scripts/start_mid70_d435i_drivers.sh
```

It validates the Compose configuration, starts the algorithm service, recreates
the privileged driver service so newly attached USB devices are visible, and
checks the LiDAR, IMU and image rates and timestamp alignment. The default check
lasts 8 seconds; use `--check-seconds 15` for a longer sample. A successful run
ends with `[PASS] D435i and MID-70 are ready`.

After that check passes, record the three FAST-LIVO input topics with:

```bash
./scripts/record_fast_livo_inputs.sh
```

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

To replay a bag instead of using live sensors, set `BAG_FILE` to a path below
the container's read-only `/bags` mount. For example:

```dotenv
BAGS_DIR=/mnt/ssd/bags
BAG_FILE=/bags/fast_livo_real/20260807_162735/fast_livo_inputs_20260807_162735_0.bag
BAG_RATE=0.5
BAG_LOOP=false
```

Then recreate only the algorithm service so the hardware drivers do not
publish duplicate sensor topics:

```bash
docker compose --env-file deploy/.env -f deploy/compose.orange-pi-5-max.yml \
  up -d --no-build --no-deps --force-recreate algorithm
```

When the bag finishes, FAST-LIVO and Foxglove remain available so the final map
can still be inspected. Clear `BAG_FILE` before returning to live sensors.

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
- librealsense defaults to its RSUSB backend so it does not depend on UVC patches in the Arch host kernel.
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
