#!/usr/bin/env -S bash -euxo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCRIPT_FILE="$(basename "$SCRIPT_PATH")"

VM_NAME="${SCRIPT_FILE%.sh}"
TART_HOME="$(dirname "$SCRIPT_DIR")"

BRIDGE_INTERFACE="${BRIDGE_INTERFACE:-Thunderbolt Ethernet Slot 1}"
TART_BIN="${TART_BIN:-tart}"
SERIAL_ENABLE="${SERIAL_ENABLE:-1}"
GRAPHICS_ENABLE="${GRAPHICS_ENABLE:-0}"
SERIAL_PATH="${SERIAL_PATH:-}"
SERIAL_TRUNCATE="${SERIAL_TRUNCATE:-1}"
SERIAL_CAPTURE_ENABLE="${SERIAL_CAPTURE_ENABLE:-1}"
SERIAL_CAPTURE_LOG="${SERIAL_CAPTURE_LOG:-$TART_HOME/serial/$VM_NAME.capture.log}"
SERIAL_CAPTURE_TIMEOUT_SECONDS="${SERIAL_CAPTURE_TIMEOUT_SECONDS:-20}"

capture_pid=""
tart_pid=""

cleanup() {
  if [[ -n "$capture_pid" ]] && kill -0 "$capture_pid" >/dev/null 2>&1; then
    kill "$capture_pid" >/dev/null 2>&1 || true
    wait "$capture_pid" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

bool_true() {
  local v="${1:-}"
  v="${v,,}"
  [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" || "$v" == "on" ]]
}

run_args=(run "$VM_NAME")
if bool_true "$GRAPHICS_ENABLE"; then
  run_args+=(--vnc-experimental)
else
  run_args+=(--no-graphics)
fi
if bool_true "$SERIAL_ENABLE"; then
  if [[ -n "$SERIAL_PATH" ]]; then
    mkdir -p "$(dirname "$SERIAL_PATH")"
    if bool_true "$SERIAL_TRUNCATE"; then
      truncate -s 0 "$SERIAL_PATH"
    else
      touch "$SERIAL_PATH"
    fi
    run_args+=("--serial-path=$SERIAL_PATH")
  else
    run_args+=(--serial)
  fi
fi

if [[ -n "$BRIDGE_INTERFACE" ]]; then
  run_args+=("--net-bridged=$BRIDGE_INTERFACE")
fi

if bool_true "$SERIAL_ENABLE" && [[ -z "$SERIAL_PATH" ]] && bool_true "$SERIAL_CAPTURE_ENABLE"; then
  mkdir -p "$(dirname "$SERIAL_CAPTURE_LOG")"
  if bool_true "$SERIAL_TRUNCATE"; then
    truncate -s 0 "$SERIAL_CAPTURE_LOG"
  else
    touch "$SERIAL_CAPTURE_LOG"
  fi

  tart_run_log="$TART_HOME/serial/$VM_NAME.tart.run.log"
  truncate -s 0 "$tart_run_log"

  "$TART_BIN" "${run_args[@]}" >"$tart_run_log" 2>&1 &
  tart_pid=$!

  pty_path=""
  for ((i = 0; i < SERIAL_CAPTURE_TIMEOUT_SECONDS * 10; i++)); do
    if ! kill -0 "$tart_pid" >/dev/null 2>&1; then
      break
    fi

    pty_path="$(grep -oE '/dev/ttys[0-9]+' "$tart_run_log" | tail -n 1 || true)"
    if [[ -n "$pty_path" ]]; then
      break
    fi
    sleep 0.1
  done

  if [[ -n "$pty_path" ]]; then
    cat "$pty_path" >>"$SERIAL_CAPTURE_LOG" &
    capture_pid=$!
    echo "[bootstrap-lab] capturing serial PTY $pty_path -> $SERIAL_CAPTURE_LOG" >&2
  else
    echo "[bootstrap-lab][WARN] no PTY detected in $tart_run_log; capture not started" >&2
  fi

  wait "$tart_pid"
  exit_code=$?
  exit "$exit_code"
else
  exec "$TART_BIN" "${run_args[@]}"
fi
