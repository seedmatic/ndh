#!/usr/bin/env -S bash -euxo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"


TART_HOME="${TART_HOME:-"$(realpath "${SCRIPT_DIR}/..")"}"; export TART_HOME
VM_NAME="${VM_NAME:-nixos-installer}"

VM_DIR="${TART_HOME}/vms/${VM_NAME}"
OPT_DIR="${OPT_DIR:-${VM_DIR}/opt}"
ISO_DISK_PATH="${ISO_DISK_PATH:-${OPT_DIR}/lib/nixos.iso}"
TANK1_DISK="${VM_DIR}/disk.img"
TANK2_DISK="${VM_DIR}/disk2.img"
TANK3_DISK="${VM_DIR}/disk3.img"

# FORCE_ISO_BOOT=1: open firmware recovery/boot picker and choose ISO entry.
FORCE_ISO_BOOT="${FORCE_ISO_BOOT:-0}"

# ATTACH_INSTALLER_ISO=1: attach installer ISO as additional read-only disk.
# Default follows FORCE_ISO_BOOT so normal boots don't keep ISO attached.
ATTACH_INSTALLER_ISO="${ATTACH_INSTALLER_ISO:-${FORCE_ISO_BOOT}}"

# ATTACH_DATA_DISKS=1: attach install target disks (disk2..disk3) with ISO.
# For strict live installer session, set ATTACH_DATA_DISKS=0.
ATTACH_DATA_DISKS="${ATTACH_DATA_DISKS:-1}"

is_vm_running() {
  tart list | grep -E "^[[:space:]]*local[[:space:]]+${VM_NAME}[[:space:]].*[[:space:]]running$" >/dev/null
}

wait_for_disk_unlock() {
  local max_wait="${1:-30}"
  local i
  for ((i = 1; i <= max_wait; i++)); do
    if ! lsof "${TANK1_DISK}" "${TANK2_DISK}" "${TANK3_DISK}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "[nixos-installer][ERROR] timed out waiting for disk unlock: ${TANK1_DISK} ${TANK2_DISK} ${TANK3_DISK}" >&2
  lsof "${TANK1_DISK}" "${TANK2_DISK}" "${TANK3_DISK}" || true
  return 1
}

args=(
  --dir="$(git rev-parse --show-toplevel)":rw,tag=ndh
  --dir="${OPT_DIR}":ro,tag=tart
)

if is_vm_running; then
  echo "[nixos-installer] VM '${VM_NAME}' is running; stopping before relaunch"
  tart stop "${VM_NAME}" || true
fi

if [[ "${ATTACH_DATA_DISKS}" == "1" ]]; then
  wait_for_disk_unlock 30
fi

if [[ "${FORCE_ISO_BOOT}" == "1" ]]; then
  args+=(--recovery)
fi

if [[ "${ATTACH_DATA_DISKS}" == "1" ]]; then
  args+=(
    --disk="${TANK2_DISK}"
    --disk="${TANK3_DISK}"
  )
fi

if [[ "${ATTACH_INSTALLER_ISO}" == "1" ]]; then
  args+=(--disk="${ISO_DISK_PATH}:ro")
fi

tart run "${args[@]}" "${VM_NAME}"
