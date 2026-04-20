set -exuo pipefail

if ! command -v tart >/dev/null 2>&1; then
  echo "[installer-lab][ERROR] tart CLI not found in PATH" >&2
  exit 1
fi
if ! command -v diskutil >/dev/null 2>&1; then
  echo "[installer-lab][ERROR] diskutil required for ASIF disk provisioning (Darwin host)." >&2
  exit 1
fi

TART_HOME="${TART_HOME:-$PWD/.tart}"; export TART_HOME

VM_NAME="${VM_NAME:-nixos-installer}"
FACTORY_RESET="${FACTORY_RESET:-1}"
DISK_SIZE="${DISK_SIZE:-100}"
TARGET_DISK_SIZE_GIB="${TARGET_DISK_SIZE_GIB:-$DISK_SIZE}"
DISK_SIZE="$TARGET_DISK_SIZE_GIB"
VM_DIR="${VM_DIR:-$TART_HOME/vms/$VM_NAME}"
OPT_DIR="${OPT_DIR:-$VM_DIR/opt}"
ISO_PATH="${ISO_PATH:-$OPT_DIR/lib/nixos.iso}"
OPT_BIN_DIR="${OPT_DIR}/bin"
STAGE1_DEST="${OPT_BIN_DIR}/nixos-zfs-installer-stage1.sh"
GUEST_TART_MOUNT="${GUEST_TART_MOUNT:-/home/nixos/tart}"
STAGE1_GUEST_PATH="${GUEST_TART_MOUNT}/bin/nixos-zfs-installer-stage1.sh"
STAGE1_SRC="${STAGE1_SRC:-$PWD/scripts/nixos-zfs-installer-stage1.sh}"
WRAPPER_SRC="${WRAPPER_SRC:-$PWD/scripts/nixos-zfs-installer-wrapper.sh}"
WRAPPER_DEST="${TART_HOME}/vms/${VM_NAME}.sh"

bool_true() {
  local v="${1:-}"
  v="${v,,}"
  [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" || "$v" == "on" ]]
}

create_blank_asif() {
  local output="$1"
  local base="$output"

  rm -f "$output" "$base.asif" "$base.dmg"
  diskutil image create blank --fs None --size "${DISK_SIZE}GiB" --format ASIF "$base" >/dev/null

  if [[ -e "$base.asif" ]]; then
    mv -f "$base.asif" "$output"
  elif [[ -e "$base.dmg" ]]; then
    mv -f "$base.dmg" "$output"
  elif [[ ! -e "$output" ]]; then
    echo "[installer-lab][ERROR] diskutil produced no ASIF output for $base" >&2
    exit 1
  fi

  chmod 0644 "$output" || true
  chmod u+w "$output" || true
  echo "[installer-lab] wrote $output"
}

mkdir -p "$VM_DIR" "$OPT_BIN_DIR" "$(dirname "$ISO_PATH")"
mkdir -p "${TART_HOME}/vms"

if [[ -f "$STAGE1_SRC" ]]; then
  install -m 0755 "$STAGE1_SRC" "${STAGE1_DEST}.tmp"
  mv -f "${STAGE1_DEST}.tmp" "$STAGE1_DEST"
  echo "[installer-lab] staged stage1 script: $STAGE1_DEST"
else
  echo "[installer-lab][ERROR] stage1 script not found at $STAGE1_SRC" >&2
  exit 1
fi

if [[ -f "$WRAPPER_SRC" ]]; then
  install -m 0755 "$WRAPPER_SRC" "${WRAPPER_DEST}.tmp"
  mv -f "${WRAPPER_DEST}.tmp" "$WRAPPER_DEST"
  echo "[installer-lab] staged wrapper: $WRAPPER_DEST"
else
  echo "[installer-lab][ERROR] wrapper script not found at $WRAPPER_SRC" >&2
  exit 1
fi

if bool_true "$FACTORY_RESET"; then
  echo "[installer-lab] factory reset VM: $VM_NAME"
  tart stop "$VM_NAME" >/dev/null 2>&1 || true
  tart delete "$VM_NAME" >/dev/null 2>&1 || true
  rm -rf "$VM_DIR"
  mkdir -p "$VM_DIR" "$OPT_BIN_DIR" "$(dirname "$ISO_PATH")"
fi

if ! tart list 2>/dev/null | sed -E 's/^[[:space:]]+//' | tr -s ' ' | cut -d' ' -f2 | grep -qx "$VM_NAME"; then
  echo "[installer-lab] creating Tart VM: $VM_NAME"
  tart create --linux "$VM_NAME" --disk-size "$DISK_SIZE" --disk-format "asif"
else
  tart stop "$VM_NAME" >/dev/null 2>&1 || true
fi

create_blank_asif "$VM_DIR/disk.img"
create_blank_asif "$VM_DIR/disk2.img"
create_blank_asif "$VM_DIR/disk3.img"


if [[ -e "$ISO_PATH" ]]; then
  echo "[installer-lab] iso=$ISO_PATH"
else
  echo "[installer-lab][WARN] ISO missing at $ISO_PATH"
fi

echo "[installer-lab] done"
echo "[installer-lab] vm=$VM_NAME"
echo "[installer-lab] vm_dir=$VM_DIR"
echo "[installer-lab] opt_dir=$OPT_DIR"
echo "[installer-lab] iso_path=$ISO_PATH"
echo "[installer-lab] stage1=$STAGE1_GUEST_PATH"
echo "[installer-lab] next: FORCE_ISO_BOOT=1 ${WRAPPER_DEST}"
