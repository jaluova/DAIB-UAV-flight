#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
image="${REALSENSE_IMAGE:-daib-realsense:ubuntu20.04-rsusb-arm64}"
builder_name="${BUILDX_BUILDER:-desktop-linux}"
build_jobs="${BUILD_JOBS:-1}"
librealsense_ref="${LIBREALSENSE_REF:-v2.55.1}"
realsense_ros_ref="${REALSENSE_ROS_REF:-2.3.2}"
proxy_url="${DAIB_BUILD_PROXY:-}"

command -v docker >/dev/null || {
  echo "docker is required" >&2
  exit 1
}
docker info >/dev/null
docker buildx inspect "$builder_name" >/dev/null
docker buildx use "$builder_name"

proxy_args=()
if [[ -n "$proxy_url" ]]; then
  proxy_args+=(
    --build-arg "HTTP_PROXY=${proxy_url}"
    --build-arg "HTTPS_PROXY=${proxy_url}"
    --build-arg "http_proxy=${proxy_url}"
    --build-arg "https_proxy=${proxy_url}"
  )
fi

docker buildx build \
  --platform linux/arm64 \
  --load \
  --tag "$image" \
  --build-arg "BUILD_JOBS=${build_jobs}" \
  --build-arg "LIBREALSENSE_REF=${librealsense_ref}" \
  --build-arg "REALSENSE_ROS_REF=${realsense_ros_ref}" \
  --build-arg REALSENSE_FORCE_RSUSB_BACKEND=ON \
  "${proxy_args[@]}" \
  --file "$repo_root/deploy/Dockerfile.realsense-ubuntu" \
  "$repo_root"

echo "Built ${image}"
