#!/usr/bin/env bash

# Keep ROS sensor timestamps sane on boards without a usable hardware RTC.
# Prefer chrony/NTP; otherwise restore the last known-good wall clock value.

ensure_clock() {
  local script_dir="${SCRIPT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
  local repo_root="${REPO_ROOT:-$(cd -- "${script_dir}/.." && pwd)}"
  local state_file="${DAIB_CLOCK_STATE_FILE:-${repo_root}/.last_clock_epoch}"
  local minimum_epoch=1735689600 # 2025-01-01 UTC
  local now saved

  if command -v chronyc >/dev/null 2>&1; then
    chronyc -a makestep >/dev/null 2>&1 || true
  fi

  now="$(date +%s)"
  if [[ -r "$state_file" ]]; then
    saved="$(tr -d '[:space:]' < "$state_file")"
    if [[ "$saved" =~ ^[0-9]+$ ]] && (( now + 300 < saved )); then
      echo "[WARN] system clock is behind the last known-good time; attempting restore"
      if sudo -n date -s "@$saved" >/dev/null 2>&1; then
        now="$(date +%s)"
      elif [[ -t 0 ]]; then
        sudo date -s "@$saved" >/dev/null \
          || { echo "[FAIL] unable to restore the system clock" >&2; return 1; }
        now="$(date +%s)"
      else
        echo "[FAIL] system clock is behind and sudo cannot run non-interactively" >&2
        echo "       Run: sudo date -s \"$(date '+%Y-%m-%d %H:%M:%S')\"" >&2
        return 1
      fi
    fi
  fi

  if (( now < minimum_epoch )); then
    echo "[FAIL] system clock is invalid: $(date -Ins)" >&2
    echo "       Run: sudo date -s \"YYYY-MM-DD HH:MM:SS\"" >&2
    return 1
  fi

  printf '%s\n' "$now" > "$state_file"
  if command -v chronyc >/dev/null 2>&1 && \
      chronyc tracking 2>/dev/null | grep -q 'Leap status[[:space:]]*:[[:space:]]*Normal'; then
    echo "[PASS] system clock is valid and chrony is synchronized: $(date -Ins)"
  else
    echo "[WARN] system clock is valid but NTP is not synchronized: $(date -Ins)"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ensure_clock
fi
