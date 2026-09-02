#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${DAIB_TMUX_CONFIG:-${SCRIPT_DIR}/tmux-flight.conf}"
SESSION_NAME="daib"
ATTACH_AFTER_START=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Create/reuse a four-pane tmux session using ${CONFIG_FILE}.

Options:
  --config FILE   Use another shell config file
  --name NAME     Override the tmux session name
  --new           Kill and recreate this session
  --no-attach     Create/reuse it without attaching
  -h, --help      Show this help

The config defines SESSION_NAME, WINDOW_NAME, PANE_0_COMMAND through
PANE_3_COMMAND, and ATTACH_AFTER_START.
EOF
}

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

RECREATE=false
ATTACH_OVERRIDE=""
SESSION_OVERRIDE=""
while (($#)); do
  case "$1" in
    --config)
      (($# >= 2)) || fail "--config requires a file"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --name)
      (($# >= 2)) || fail "--name requires a value"
      SESSION_OVERRIDE="$2"
      shift 2
      ;;
    --new)
      RECREATE=true
      shift
      ;;
    --no-attach)
      ATTACH_OVERRIDE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

command -v tmux >/dev/null || fail "tmux is not installed"
[[ -r "$CONFIG_FILE" ]] || fail "config file is not readable: $CONFIG_FILE"

# shellcheck disable=SC1090
source "$CONFIG_FILE"
SESSION_NAME="${SESSION_OVERRIDE:-${SESSION_NAME:-daib}}"
WINDOW_NAME="${WINDOW_NAME:-flight}"
ATTACH_AFTER_START="${ATTACH_OVERRIDE:-${ATTACH_AFTER_START:-1}}"

if [[ "$RECREATE" == true ]] && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  tmux kill-session -t "$SESSION_NAME"
fi

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  tmux new-session -d -s "$SESSION_NAME" -n "$WINDOW_NAME"
  tmux split-window -h -t "${SESSION_NAME}:${WINDOW_NAME}.0"
  tmux split-window -v -t "${SESSION_NAME}:${WINDOW_NAME}.0"
  tmux split-window -v -t "${SESSION_NAME}:${WINDOW_NAME}.1"
  tmux select-layout -t "${SESSION_NAME}:${WINDOW_NAME}" tiled

  mapfile -t panes < <(tmux list-panes -t "${SESSION_NAME}:${WINDOW_NAME}" -F '#{pane_id}')
  ((${#panes[@]} == 4)) || fail "expected four panes, found ${#panes[@]}"

  commands=("${PANE_0_COMMAND:-}" "${PANE_1_COMMAND:-}" "${PANE_2_COMMAND:-}" "${PANE_3_COMMAND:-}")
  for i in "${!panes[@]}"; do
    [[ -n "${commands[$i]}" ]] || continue
    tmux send-keys -t "${panes[$i]}" "${commands[$i]}" C-m
  done
fi

echo "tmux session ready: ${SESSION_NAME}"
echo "attach: tmux attach -t ${SESSION_NAME}"
echo "detach: Ctrl-b d"

if [[ "$ATTACH_AFTER_START" == 1 ]]; then
  exec tmux attach-session -t "$SESSION_NAME"
fi
