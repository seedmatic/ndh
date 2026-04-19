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

IFS=',' read -r -a part_labels <<< "$PART_LABELS_CSV"
if [[ "${#part_labels[@]}" -lt 1 ]]; then
  echo "[stage1-lab][ERROR] expected at least 1 partition label in PART_LABELS_CSV, got: ${#part_labels[@]}" >&2
  exit 1
fi

required_disks=1
case "$POOL_TOPOLOGY" in
  mirror)
    required_disks=2
    ;;
  raidz1)
    required_disks=3
    ;;
  raidz2)
    required_disks=4
    ;;
  raidz3)
    required_disks=5
    ;;
  single|stripe|none)
    required_disks=1
    ;;
  *)
    echo "[stage1-lab][ERROR] unsupported POOL_TOPOLOGY='$POOL_TOPOLOGY' (expected one of: mirror, raidz1, raidz2, raidz3, single)" >&2
    exit 1
    ;;
esac

if [[ "${#part_labels[@]}" -lt "$required_disks" ]]; then
  echo "[stage1-lab][ERROR] expected at least $required_disks partition labels for topology '$POOL_TOPOLOGY', got: ${#part_labels[@]}" >&2
  exit 1
fi

if [[ "$DISKS_CSV" == "auto" ]]; then
  mapfile -t detected_disks < <(
    lsblk -dnpo NAME,TYPE \
      | while read -r name type; do
          [[ "$type" == "disk" ]] && printf '%s\n' "$name"
        done \
      | grep -E '^/dev/vd[a-z]$' \
      | sort
  )

  if [[ "${#detected_disks[@]}" -lt "$required_disks" ]]; then
    echo "[stage1-lab][ERROR] auto-detect found fewer than $required_disks extra candidate pool disks for topology '$POOL_TOPOLOGY'" >&2
    lsblk -dnpo NAME,TYPE,SIZE,MODEL >&2 || true
    exit 1
  fi

  disks=("${detected_disks[@]:0:$required_disks}")
  echo "[stage1-lab] auto-selected extra pool disks: ${disks[*]}"
else
  IFS=',' read -r -a disks <<< "$DISKS_CSV"
fi

if [[ "${#disks[@]}" -lt "$required_disks" ]]; then
  echo "[stage1-lab][ERROR] expected at least $required_disks extra pool disks for topology '$POOL_TOPOLOGY', got: ${#disks[@]}" >&2
  exit 1
fi

if [[ "${#part_labels[@]}" -lt "${#disks[@]}" ]]; then
  echo "[stage1-lab][ERROR] PART_LABELS_CSV has fewer entries (${#part_labels[@]}) than selected disks (${#disks[@]})" >&2
  exit 1
fi

for d in "${disks[@]}"; do
  if [[ ! -b "$d" ]]; then
    echo "[stage1-lab][ERROR] missing block device: $d" >&2
    exit 1
  fi
  if lsblk -nrpo MOUNTPOINT "$d" | grep -Eq '[^[:space:]]'; then
    echo "[stage1-lab][ERROR] refusing to use mounted disk: $d" >&2
    lsblk -nrpo NAME,FSTYPE,MOUNTPOINT "$d" >&2 || true
    exit 1
  fi
done

if zpool list -H -o name "$POOL_NAME" >/dev/null 2>&1; then
  if [[ "$RESET_POOL" == "1" ]]; then
    umount "$TARGET_MOUNT/home" >/dev/null 2>&1 || true
    umount "$TARGET_MOUNT/nix" >/dev/null 2>&1 || true
    umount "$TARGET_MOUNT" >/dev/null 2>&1 || true
    echo "[stage1-lab] destroying existing pool $POOL_NAME"
    zpool destroy -f "$POOL_NAME"
  else
    echo "[stage1-lab][ERROR] pool exists: $POOL_NAME (set RESET_POOL=1 to recreate)" >&2
    exit 1
  fi
fi

umount "$TARGET_MOUNT/home" >/dev/null 2>&1 || true
umount "$TARGET_MOUNT/boot/efi" >/dev/null 2>&1 || true
umount "$TARGET_MOUNT/boot" >/dev/null 2>&1 || true

esp_labels=()
for i in "${!disks[@]}"; do
  d="${disks[$i]}"
  label="${part_labels[$i]}"
  esp_label="$BOOT_PART_LABEL"
  if [[ "$i" -gt 0 ]]; then
    esp_label="${BOOT_PART_LABEL}$((i + 1))"
  fi
  esp_labels+=("$esp_label")

  echo "[stage1-lab] clearing signatures on $d"
  zpool labelclear -f "$d" >/dev/null 2>&1 || true
  wipefs -a "$d" >/dev/null 2>&1 || true
  blkdiscard -f "$d" >/dev/null 2>&1 || true
  echo "[stage1-lab] partitioning $d: EFI($esp_label), rpool($label), swap"
  sgdisk --zap-all "$d"
  sgdisk --clear "$d"
  sgdisk -n 1:1MiB:+"$EFI_SIZE" -t 1:EF00 -c 1:"$esp_label" "$d"
  sgdisk -n 2:0:-$((SWAPSIZE + RESERVE))GiB -t 2:BF01 -c 2:"$label" "$d"
  sgdisk -n 3:0:-${RESERVE}GiB -t 3:8200 -c 3:"swap$((i + 1))" "$d"
done

udevadm settle

for esp_label in "${esp_labels[@]}"; do
  esp_part="/dev/disk/by-partlabel/$esp_label"
  if [[ ! -e "$esp_part" ]]; then
    echo "[stage1-lab][ERROR] missing EFI partition by label: $esp_part" >&2
    ls -l /dev/disk/by-partlabel >&2 || true
    exit 1
  fi
  mkfs.vfat -F 32 -n "$BOOT_FS_LABEL" "$esp_part"
done

BOOT_PART="/dev/disk/by-partlabel/${esp_labels[0]}"
ESP_PARTS=( )
for esp_label in "${esp_labels[@]}"; do
  ESP_PARTS+=("/dev/disk/by-partlabel/$esp_label")
done

pool_parts=()
for i in "${!disks[@]}"; do
  label="${part_labels[$i]}"
  part="/dev/disk/by-partlabel/$label"
  if [[ ! -e "$part" ]]; then
    echo "[stage1-lab][ERROR] missing partition by label: $part" >&2
    ls -l /dev/disk/by-partlabel >&2 || true
    exit 1
  fi
  pool_parts+=("$part")
done
echo "[stage1-lab] pool members (by-partlabel): ${pool_parts[*]}"

echo "[stage1-lab] creating pool $POOL_NAME"
zpool_args=(
  -f
  -o ashift=12
  -o autotrim=on
  -O acltype=posixacl
  -O canmount=off
  -O dnodesize=auto
  -O normalization=formD
  -O relatime=on
  -O xattr=sa
  -O mountpoint=none
  "$POOL_NAME"
)

case "$POOL_TOPOLOGY" in
  mirror|raidz1|raidz2|raidz3)
    zpool_args+=("$POOL_TOPOLOGY")
    ;;
  single|stripe|none)
    ;;
esac

zpool create "${zpool_args[@]}" "${pool_parts[@]}"

echo "[stage1-lab] creating datasets"
zfs create -o mountpoint=legacy "$ROOT_DATASET"
zfs create -o mountpoint=legacy "$NIX_DATASET"
zfs create -o mountpoint=legacy "$HOME_DATASET"
zpool set bootfs="$ROOT_DATASET" "$POOL_NAME"

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
