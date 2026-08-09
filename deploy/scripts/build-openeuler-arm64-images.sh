#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
output_dir="${1:-${repo_root}/dist}"
algorithm_image="${ALGORITHM_IMAGE:-daib-algorithm:openeuler-arm64}"
drivers_image="${DRIVERS_IMAGE:-daib-drivers:openeuler-arm64}"
builder_name="${BUILDX_BUILDER:-desktop-linux}"
build_jobs="${BUILD_JOBS:-1}"
vikit_ref="${VIKIT_REF:-master}"
arm_flags="${FAST_LIVO_ARM_FLAGS:--march=armv8-a}"
realsense_backend="${REALSENSE_FORCE_RSUSB_BACKEND:-ON}"
proxy_url="${DAIB_BUILD_PROXY:-}"

write_sha256() {
  local file="$1"
  local directory basename
  directory="$(dirname -- "$file")"
  basename="$(basename -- "$file")"
  if command -v sha256sum >/dev/null; then
    (cd "$directory" && sha256sum "$basename" > "$basename.sha256")
  else
    (cd "$directory" && shasum -a 256 "$basename" > "$basename.sha256")
  fi
}

command -v docker >/dev/null || {
  echo "docker is required" >&2
  exit 1
}
docker info >/dev/null
docker buildx version >/dev/null
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

mkdir -p "$output_dir"
docker buildx build \
  --platform linux/arm64 \
  --load \
  --tag "$algorithm_image" \
  --build-arg "BUILD_JOBS=${build_jobs}" \
  --build-arg "VIKIT_REF=${vikit_ref}" \
  --build-arg "FAST_LIVO_ARM_FLAGS=${arm_flags}" \
  "${proxy_args[@]}" \
  --file "$repo_root/deploy/Dockerfile.algorithm" \
  "$repo_root"

docker buildx build \
  --platform linux/arm64 \
  --load \
  --tag "$drivers_image" \
  --build-arg "BUILD_JOBS=${build_jobs}" \
  --build-arg "REALSENSE_FORCE_RSUSB_BACKEND=${realsense_backend}" \
  "${proxy_args[@]}" \
  --file "$repo_root/deploy/Dockerfile.drivers" \
  "$repo_root"

archive="$output_dir/daib-openeuler-arm64-images.tar.gz"
docker save "$algorithm_image" "$drivers_image" | gzip -1 > "$archive"
write_sha256 "$archive"

echo "Created $archive"
echo "Load on the Orange Pi 5 Max with: gzip -dc $(basename "$archive") | docker load"
