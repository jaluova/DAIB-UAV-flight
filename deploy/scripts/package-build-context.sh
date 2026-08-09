#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
output_file="${1:-${repo_root}/dist/daib-container-source.tar.gz}"

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

mkdir -p "$(dirname -- "$output_file")"

archive_inputs=(
  .dockerignore
  README.md
  deploy
  docs
  patches
  scripts
  src/DAIB-LIVO
  src/DAIB-Planner
  src/DAIB-Explorer
)
if [[ -f "${repo_root}/CLAUDE.md" ]]; then
  archive_inputs+=(CLAUDE.md)
fi

tar -C "$repo_root" -czf "$output_file" \
  --exclude-vcs \
  --exclude='*/__pycache__' \
  --exclude='*.py[cod]' \
  --exclude='*.log' \
  --exclude='*.zip' \
  --exclude='*~' \
  --exclude='.DS_Store' \
  --exclude='*/.DS_Store' \
  --exclude='*/.vscode' \
  --exclude='src/DAIB-LIVO/Log' \
  --exclude='src/DAIB-LIVO/pics' \
  --exclude='src/DAIB-LIVO/Supplementary' \
  --exclude='src/DAIB-Planner/pictures' \
  "${archive_inputs[@]}"

write_sha256 "$output_file"
du -h "$output_file" "$output_file.sha256"
