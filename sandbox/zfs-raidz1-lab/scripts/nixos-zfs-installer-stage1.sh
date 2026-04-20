#!/usr/bin/env -S bash -euxo pipefail

# Execute this script INSIDE nixos-installer VM from the mounted Tart share,
# e.g. /home/nixos/tart/bin/stage1-nixos-zfs-install.sh (or /opt/bin if mounted there).

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[stage1-lab][ERROR] run this script with sudo:" >&2
  echo "[stage1-lab][ERROR]   sudo /home/nixos/tart/bin/stage1-nixos-zfs-install.sh" >&2
  exit 1
fi

POOL_NAME="${POOL_NAME:-tank}"
ROOT_DATASET="${ROOT_DATASET:-${POOL_NAME}/root}"
NIX_DATASET="${NIX_DATASET:-${POOL_NAME}/nix}"
HOME_DATASET="${HOME_DATASET:-${POOL_NAME}/home}"
DISKS_CSV="${DISKS_CSV:-auto}"
PART_LABELS_CSV="${PART_LABELS_CSV:-tank1,tank2,tank3}"
POOL_TOPOLOGY="${POOL_TOPOLOGY:-raidz1}"
TARGET_MOUNT="${TARGET_MOUNT:-/mnt}"
ZPOOL_INIT_SERVICE="${ZPOOL_INIT_SERVICE:-io-nxmatic-nix-darwin-home-zpool-init.service}"
ZPOOL_INIT_WAIT_TIMEOUT="${ZPOOL_INIT_WAIT_TIMEOUT:-1800}"
ZPOOL_INIT_MODE="${ZPOOL_INIT_MODE:-start}"
BOOT_PART_LABEL="${BOOT_PART_LABEL:-esp}"
BOOT_FS_LABEL="${BOOT_FS_LABEL:-NIXBOOT}"
EFI_SIZE="${EFI_SIZE:-4GiB}"
SWAPSIZE="${SWAPSIZE:-4}"
RESERVE="${RESERVE:-1}"
RESET_POOL="${RESET_POOL:-1}"
INSTALL_NIXOS="${INSTALL_NIXOS:-1}"
INSTALL_MODE="${INSTALL_MODE:-flake}"
INSTALL_FLAKE="${INSTALL_FLAKE:-/home/nixos/ndh/sandbox/zfs-raidz1-lab#nixos-installer-zfs-lab}"
GENERATE_CONFIG="${GENERATE_CONFIG:-1}"
TART_SHARE_MOUNT="${TART_SHARE_MOUNT:-/home/nixos/tart}"

echo "[stage1-lab] pool_name=$POOL_NAME"
echo "[stage1-lab] root_dataset=$ROOT_DATASET"
echo "[stage1-lab] nix_dataset=$NIX_DATASET"
echo "[stage1-lab] home_dataset=$HOME_DATASET"
echo "[stage1-lab] disks_csv=$DISKS_CSV"
echo "[stage1-lab] part_labels_csv=$PART_LABELS_CSV"
echo "[stage1-lab] pool_topology=$POOL_TOPOLOGY"
echo "[stage1-lab] target_mount=$TARGET_MOUNT"
echo "[stage1-lab] zpool_init_service=$ZPOOL_INIT_SERVICE"
echo "[stage1-lab] zpool_init_wait_timeout=$ZPOOL_INIT_WAIT_TIMEOUT"
echo "[stage1-lab] zpool_init_mode=$ZPOOL_INIT_MODE"
echo "[stage1-lab] boot_part_label=$BOOT_PART_LABEL"
echo "[stage1-lab] boot_fs_label=$BOOT_FS_LABEL"
echo "[stage1-lab] efi_size=$EFI_SIZE"
echo "[stage1-lab] swapsize_gib=$SWAPSIZE"
echo "[stage1-lab] reserve_gib=$RESERVE"
echo "[stage1-lab] reset_pool=$RESET_POOL"
echo "[stage1-lab] install_nixos=$INSTALL_NIXOS"
echo "[stage1-lab] install_mode=$INSTALL_MODE"
echo "[stage1-lab] install_flake=$INSTALL_FLAKE"
echo "[stage1-lab] generate_config=$GENERATE_CONFIG"
echo "[stage1-lab] tart_share_mount=$TART_SHARE_MOUNT"

case "$ZPOOL_INIT_MODE" in
  start|skip|inspect)
    ;;
  *)
    echo "[stage1-lab][ERROR] unsupported ZPOOL_INIT_MODE='$ZPOOL_INIT_MODE' (expected: start|skip|inspect)" >&2
    exit 1
    ;;
esac

if [[ "$ZPOOL_INIT_MODE" == "inspect" ]]; then
  echo "[stage1-lab] inspect mode: runtime-masking zpool-init and showing disk/pool layout"
  if systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -Fxq "$ZPOOL_INIT_SERVICE"; then
    pre_state="$(systemctl show -p ActiveState --value "$ZPOOL_INIT_SERVICE" || true)"
    pre_sub_state="$(systemctl show -p SubState --value "$ZPOOL_INIT_SERVICE" || true)"
    pre_result="$(systemctl show -p Result --value "$ZPOOL_INIT_SERVICE" || true)"
    echo "[stage1-lab] pre-inspect unit state: active=$pre_state substate=$pre_sub_state result=$pre_result"
    systemctl stop "$ZPOOL_INIT_SERVICE" || true
    systemctl reset-failed "$ZPOOL_INIT_SERVICE" || true
    systemctl mask --runtime "$ZPOOL_INIT_SERVICE" || true
    post_state="$(systemctl show -p ActiveState --value "$ZPOOL_INIT_SERVICE" || true)"
    post_sub_state="$(systemctl show -p SubState --value "$ZPOOL_INIT_SERVICE" || true)"
    post_result="$(systemctl show -p Result --value "$ZPOOL_INIT_SERVICE" || true)"
    post_unit_file_state="$(systemctl show -p UnitFileState --value "$ZPOOL_INIT_SERVICE" || true)"
    echo "[stage1-lab] post-inspect unit state: active=$post_state substate=$post_sub_state result=$post_result unit_file_state=$post_unit_file_state"
    if [[ "$pre_state" == "active" && "$pre_result" == "success" ]]; then
      echo "[stage1-lab][WARN] zpool-init service had already completed earlier in this boot"
    fi
  else
    echo "[stage1-lab][WARN] inspect mode: service unit not found, continuing with layout lookup"
  fi
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,PARTLABEL || true
  echo "[stage1-lab] /dev/disk/by-partlabel"
  ls -l /dev/disk/by-partlabel || true
  echo "[stage1-lab] zpool import candidates"
  zpool import || true
  echo "[stage1-lab] zpool status"
  zpool status || true
  echo "[stage1-lab] note: runtime mask is temporary for this boot; use 'systemctl unmask $ZPOOL_INIT_SERVICE' before start mode if needed"
  echo '[stage1-lab] VM_STAGE1_LOOKUP_OK'
  exit 0
fi

echo "[stage1-lab] delegating pool provisioning to systemd service: $ZPOOL_INIT_SERVICE"
if ! systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -Fxq "$ZPOOL_INIT_SERVICE"; then
  echo "[stage1-lab][ERROR] zpool-init service not found: $ZPOOL_INIT_SERVICE" >&2
  systemctl list-unit-files --type=service | grep -E 'zpool|nxmatic' >&2 || true
  exit 1
fi

if [[ "$ZPOOL_INIT_MODE" == "start" ]]; then
  systemctl start "$ZPOOL_INIT_SERVICE"
else
  echo "[stage1-lab] skip mode: not starting $ZPOOL_INIT_SERVICE (expect it to be already provisioned)"
fi

state="$(systemctl show -p ActiveState --value "$ZPOOL_INIT_SERVICE" || true)"
sub_state="$(systemctl show -p SubState --value "$ZPOOL_INIT_SERVICE" || true)"
result="$(systemctl show -p Result --value "$ZPOOL_INIT_SERVICE" || true)"

if [[ "$state" != "active" || "$result" != "success" ]]; then
  echo "[stage1-lab][ERROR] zpool-init service failed state=$state substate=$sub_state result=$result" >&2
  systemctl status "$ZPOOL_INIT_SERVICE" --no-pager >&2 || true
  journalctl -u "$ZPOOL_INIT_SERVICE" -n 200 --no-pager >&2 || true
  exit 1
fi

if ! zpool list -H -o name "$POOL_NAME" >/dev/null 2>&1; then
  echo "[stage1-lab][ERROR] expected pool missing after zpool-init: $POOL_NAME" >&2
  zpool list >&2 || true
  exit 1
fi

mapfile -t ESP_PARTS < <(ls -1 /dev/disk/by-partlabel/esp* 2>/dev/null | sort)
if [[ "${#ESP_PARTS[@]}" -eq 0 ]]; then
  echo "[stage1-lab][ERROR] no ESP partitions found at /dev/disk/by-partlabel/esp* after zpool-init" >&2
  ls -l /dev/disk/by-partlabel >&2 || true
  exit 1
fi

BOOT_PART="${ESP_PARTS[0]}"
echo "[stage1-lab] detected ESP partitions: ${ESP_PARTS[*]}"
echo "[stage1-lab] selected primary ESP: $BOOT_PART"

if ! zfs list -H -o name "$ROOT_DATASET" >/dev/null 2>&1; then
  echo "[stage1-lab][ERROR] root dataset not found after zpool-init: $ROOT_DATASET" >&2
  zfs list -r "$POOL_NAME" >&2 || true
  exit 1
fi

if ! zfs list -H -o name "$NIX_DATASET" >/dev/null 2>&1; then
  echo "[stage1-lab][ERROR] nix dataset not found after zpool-init: $NIX_DATASET" >&2
  zfs list -r "$POOL_NAME" >&2 || true
  exit 1
fi

if ! zfs list -H -o name "$HOME_DATASET" >/dev/null 2>&1; then
  echo "[stage1-lab][ERROR] home dataset not found after zpool-init: $HOME_DATASET" >&2
  zfs list -r "$POOL_NAME" >&2 || true
  exit 1
fi

mkdir -p "$TARGET_MOUNT"
umount "$TARGET_MOUNT/home" >/dev/null 2>&1 || true
umount "$TARGET_MOUNT/nix" >/dev/null 2>&1 || true
umount "$TARGET_MOUNT/boot/efi" >/dev/null 2>&1 || true
umount "$TARGET_MOUNT/boot" >/dev/null 2>&1 || true
umount "$TARGET_MOUNT" >/dev/null 2>&1 || true
mount -t zfs "$ROOT_DATASET" "$TARGET_MOUNT"
mkdir -p "$TARGET_MOUNT/nix"
mount -t zfs "$NIX_DATASET" "$TARGET_MOUNT/nix"
mkdir -p "$TARGET_MOUNT/home"
mount -t zfs "$HOME_DATASET" "$TARGET_MOUNT/home"
mkdir -p "$TARGET_MOUNT/boot/efi"
mount -t vfat "$BOOT_PART" "$TARGET_MOUNT/boot/efi"

if [[ "$INSTALL_NIXOS" == "1" ]]; then
  echo "[stage1-lab] installing NixOS (mode=$INSTALL_MODE)"
  if [[ "$GENERATE_CONFIG" == "1" ]]; then
    nixos-generate-config --root "$TARGET_MOUNT" || true
  fi

  if [[ "$INSTALL_MODE" == "flake" ]]; then
    echo "[stage1-lab] using flake: $INSTALL_FLAKE"
    nixos-install --root "$TARGET_MOUNT" --flake "$INSTALL_FLAKE" --no-root-passwd
  else
    echo "[stage1-lab] using generic nixos-install (no flake)"
    nixos-install --root "$TARGET_MOUNT" --no-root-passwd
  fi

  if [[ "${#ESP_PARTS[@]}" -gt 1 ]]; then
    echo "[stage1-lab] mirroring primary ESP contents to additional ESP partitions"
    primary_esp="$TARGET_MOUNT/boot/efi"
    for i in "${!ESP_PARTS[@]}"; do
      if [[ "$i" -eq 0 ]]; then
        continue
      fi
      esp_part="${ESP_PARTS[$i]}"
      esp_mount="/tmp/stage1-esp-$((i + 1))"
      mkdir -p "$esp_mount"
      mount -t vfat "$esp_part" "$esp_mount"
      cp -a "$primary_esp/." "$esp_mount/"
      sync
      umount "$esp_mount"
      rmdir "$esp_mount"
      echo "[stage1-lab] mirrored ESP to $esp_part"
    done
  fi

else
  echo "[stage1-lab] INSTALL_NIXOS=0 -> skipping nixos-install (provision-only mode)"
fi

zpool status "$POOL_NAME" || true
mount | grep -E 'tank/| /mnt| /nix| /boot' || true
echo '[stage1-lab] VM_STAGE1_OK'
