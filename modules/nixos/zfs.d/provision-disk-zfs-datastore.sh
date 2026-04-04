#!/usr/bin/env bash
# provision-disk-zfs-datastore: prepare disk layout and ZFS datastore inside guest
# - Runs disko (format+mount), converts ZFS mountpoints to legacy, exports pools
# - System bootloader/switch/rebuild is handled remotely by host workflow

set -euo pipefail

DISKO_NIX="${DISKO_NIX:-${DISKO_NIX_DEFAULT:-/etc/nixos/disko.nix}}"

: "→ running disko configuration"
if [ -f "${DISKO_NIX}" ]; then
  disko --mode format,mount "${DISKO_NIX}" || : "→ WARNING: disko failed"
else
  : "→ WARNING: disko.nix not found at expected path"
fi
zfs umount -a || true

: "→ setting ZFS mountpoints to legacy from generated fstab"
fstab="/nix/var/nix/profiles/system/etc/fstab"
if [ -r "$fstab" ]; then
  awk '$3 == "zfs" { print $1 }' "$fstab" | while read -r dataset; do
    zfs set mountpoint=legacy "$dataset" || : "→ WARN: failed to set legacy on $dataset"
  done
else
  : "→ WARNING: fstab not readable: $fstab"
fi

: "→ exporting all ZFS pools"
zpool export -a || : "→ WARNING: zpool export failed"

: "→ datastore provisioning complete"
