#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
echo "build-arm64-images.sh is deprecated; building the openEuler ARM64 images." >&2
exec "${script_dir}/build-openeuler-arm64-images.sh" "$@"
