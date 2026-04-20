# @codebase
set -euo pipefail

check_drive_free_space() {
  local drive_file="$1"
  local min_free_bytes="${NDH_QEMU_MIN_FREE_BYTES:-2147483648}"
  local drive_dir available_bytes

  [[ -n "$drive_file" ]] || return 0
  [[ -e "$drive_file" ]] || return 0
  [[ "$min_free_bytes" =~ ^[0-9]+$ ]] || return 0

  drive_dir="$(dirname "$drive_file")"
  available_bytes="$(df -PB1 "$drive_dir" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "$available_bytes" =~ ^[0-9]+$ ]] || return 0

  if (( available_bytes < min_free_bytes )); then
    echo "[vm-tools][ERROR] insufficient free space for qemu drive writes: dir=$drive_dir avail=${available_bytes}B required_min=${min_free_bytes}B file=$drive_file" >&2
    echo "[vm-tools][ERROR] tune NDH_QEMU_MIN_FREE_BYTES to adjust this guard" >&2
    exit 28
  fi
}

extract_drive_file() {
  local drive_opts="$1"
  local file_part

  file_part="$(awk -F',' '{for (i=1; i<=NF; i++) if ($i ~ /^file=/) {print substr($i,6); exit}}' <<< "$drive_opts")"
  echo "$file_part"
}

rewritten=()
expect_drive_opts=0
for arg in "$@"; do
  if [[ $expect_drive_opts -eq 1 ]]; then
    drive_file="$(extract_drive_file "$arg")"
    check_drive_free_space "$drive_file"

    if [[ "$arg" == *"file="* && "$arg" != *"format="* ]]; then
      arg="${arg},format=raw"
    fi
    expect_drive_opts=0
    rewritten+=("$arg")
    continue
  fi

  rewritten+=("$arg")
  if [[ "$arg" == "-drive" ]]; then
    expect_drive_opts=1
  fi
done

qemu_pid=""

cleanup_qemu() {
  if [[ -n "${qemu_pid:-}" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
}

trap cleanup_qemu EXIT INT TERM HUP

@qemuBin@ "${rewritten[@]}" &
qemu_pid="$!"

if wait "$qemu_pid"; then
  qemu_rc=0
else
  qemu_rc=$?
fi

trap - EXIT INT TERM HUP
exit "$qemu_rc"
