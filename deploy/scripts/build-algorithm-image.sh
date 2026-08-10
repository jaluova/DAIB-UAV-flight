#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
output_dir="${1:-${repo_root}/dist}"
image="${ALGORITHM_IMAGE:-daib-algorithm:openeuler-arm64}"
builder_name="${BUILDX_BUILDER:-desktop-linux}"
build_jobs="${BUILD_JOBS:-1}"
proxy_url="${DAIB_BUILD_PROXY:-}"

command -v docker >/dev/null || {
  echo "docker is required" >&2
  exit 1
}
command -v zstd >/dev/null || {
  echo "zstd is required" >&2
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
  --build-arg "VIKIT_REF=${VIKIT_REF:-master}" \
  --build-arg "FAST_LIVO_ARM_FLAGS=${FAST_LIVO_ARM_FLAGS:--march=armv8-a}" \
  --build-arg "FOXGLOVE_BRIDGE_REF=${FOXGLOVE_BRIDGE_REF:-0.8.5}" \
  --build-arg "ROS_BABEL_FISH_REF=${ROS_BABEL_FISH_REF:-0.9.3}" \
  --build-arg "WEBSOCKETPP_REF=${WEBSOCKETPP_REF:-0.8.2}" \
  ${proxy_args[@]+"${proxy_args[@]}"} \
  --file "$repo_root/deploy/Dockerfile.algorithm" \
  "$repo_root"

mkdir -p "$output_dir"
archive="$output_dir/daib-algorithm-openeuler-arm64.tar.zst"
docker save "$image" | zstd -T0 -3 -f -o "$archive"
(
  cd "$output_dir"
  if command -v sha256sum >/dev/null; then
    sha256sum "$(basename -- "$archive")" > "$(basename -- "$archive").sha256"
  else
    shasum -a 256 "$(basename -- "$archive")" > "$(basename -- "$archive").sha256"
  fi
)

echo "Created $archive"
echo "Load with: docker load -i $(basename -- "$archive")"
