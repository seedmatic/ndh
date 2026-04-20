set -euo pipefail

if ! command -v tart >/dev/null 2>&1; then
  echo "[bootstrap-lab][ERROR] tart CLI not found in PATH" >&2
  exit 1
fi
if ! command -v diskutil >/dev/null 2>&1; then
  echo "[bootstrap-lab][ERROR] diskutil required for ASIF conversion (Darwin host)." >&2
  exit 1
fi

VM_NAME="${VM_NAME:-@DEFAULT_VM_NAME@}"
TART_HOME="${TART_HOME:-$HOME/.tart}"
VM_DIR="${VM_DIR:-$TART_HOME/vms/$VM_NAME}"
FACTORY_RESET="${FACTORY_RESET:-1}"
WRAPPER_TEMPLATE="@WRAPPER_TEMPLATE_PATH@"
TARGET_DISK_SIZE_GIB="${TARGET_DISK_SIZE_GIB:-24}"

raw_out="$(nix build -L -v -v --no-link --print-out-paths .#@IMAGE_ATTR@)"
raw_img="$raw_out/nixos.img"

mkdir -p "$VM_DIR"

convert_one() {
  local input="$1"
  local output="$2"
  local base
  local desired_bytes
  local total_bytes
  local sector_count
  local resize_ok=0
  base="$output"

  rm -f "$output" "$base.asif" "$base.dmg"
  diskutil image create from "$input" --format ASIF "$base" >/dev/null

  if [[ -n "$TARGET_DISK_SIZE_GIB" ]]; then
    if [[ ! "$TARGET_DISK_SIZE_GIB" =~ ^[0-9]+$ ]] || (( TARGET_DISK_SIZE_GIB <= 0 )); then
      echo "[bootstrap-lab][ERROR] TARGET_DISK_SIZE_GIB must be a positive integer; got '$TARGET_DISK_SIZE_GIB'" >&2
      exit 1
    fi

    desired_bytes=$(( TARGET_DISK_SIZE_GIB * 1024 * 1024 * 1024 ))
    echo "[bootstrap-lab] resizing ASIF disk to ${TARGET_DISK_SIZE_GIB}GiB (${desired_bytes} bytes): $output"

    if diskutil image resize "$output" --size "${TARGET_DISK_SIZE_GIB}g" >/dev/null 2>&1; then
      resize_ok=1
    elif diskutil image resize "$output" --sectors "$(( TARGET_DISK_SIZE_GIB * 1024 * 1024 * 1024 / 512 ))" >/dev/null 2>&1; then
      resize_ok=1
    elif command -v hdiutil >/dev/null 2>&1 && hdiutil resize -size "${TARGET_DISK_SIZE_GIB}g" "$output" >/dev/null 2>&1; then
      resize_ok=1
    fi

    if [[ "$resize_ok" != "1" ]]; then
      echo "[bootstrap-lab][ERROR] failed to resize ASIF image to ${TARGET_DISK_SIZE_GIB}GiB: $output" >&2
      exit 1
    fi

    total_bytes="$(diskutil image info --plist "$output" | yq -p=xml -r '.plist.dict[] | select(has("key") and .key == "Size Info") | .dict.integer[3] // "0"' 2>/dev/null || echo 0)"
    sector_count="$(diskutil image info --plist "$output" | yq -p=xml -r '.plist.dict[] | select(has("key") and .key == "Size Info") | .dict.integer[2] // "0"' 2>/dev/null || echo 0)"

    if [[ "$total_bytes" =~ ^[0-9]+$ ]] && (( total_bytes > 0 )); then
      echo "[bootstrap-lab] ASIF size report: total_bytes=${total_bytes} sector_count=${sector_count} file=${output}"
      if (( total_bytes < desired_bytes )); then
        echo "[bootstrap-lab][ERROR] ASIF size verification failed: expected >= ${desired_bytes} bytes, got ${total_bytes}" >&2
        exit 1
      fi
    else
      echo "[bootstrap-lab][WARN] unable to parse ASIF size info after resize; continuing" >&2
    fi
  fi

  echo "[bootstrap-lab] wrote $output"
}

bool_true() {
  local v="${1:-}"
  v="${v,,}"
  [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" || "$v" == "on" ]]
}

if bool_true "$FACTORY_RESET"; then
  echo "[bootstrap-lab] factory reset VM: $VM_NAME"
  tart stop "$VM_NAME" >/dev/null 2>&1 || true
  tart delete "$VM_NAME" >/dev/null 2>&1 || true
  rm -rf "$VM_DIR"
  mkdir -p "$VM_DIR"
  tart create --linux "$VM_NAME"
else
  if ! tart list 2>/dev/null | sed -E 's/^[[:space:]]+//' | tr -s ' ' | cut -d' ' -f1 | grep -qx "$VM_NAME"; then
    echo "[bootstrap-lab] creating Tart VM: $VM_NAME"
    tart create --linux "$VM_NAME"
  fi
  tart stop "$VM_NAME" >/dev/null 2>&1 || true
fi

convert_one "$raw_img" "$VM_DIR/disk.img"

wrapper="$TART_HOME/vms/$VM_NAME.sh"
cat "$WRAPPER_TEMPLATE" >"$wrapper"
chmod +x "$wrapper"

echo "[bootstrap-lab] materialized Tart VM assets"
echo "[bootstrap-lab] vm_dir=$VM_DIR"
echo "[bootstrap-lab] wrapper=$wrapper"
