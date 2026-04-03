#!/usr/bin/env bash
# bootstrap-zfs: prepare and configure ZFS-based NixOS system inside Lima guest
# - Optionally invokes lima-nixos-config service (idempotent)
# - Runs nixos-rebuild boot, disko (format+mount), converts mountpoints to legacy, exports pools
# Logging uses colon-prefixed no-op commands for concise, structured journal lines

set -euo pipefail

: "→ activating lima-nixos-config service (idempotent)"
if systemctl list-unit-files | grep -q '^lima-nixos-config.service'; then
  systemctl start lima-nixos-config.service || true
fi

: "→ ensuring /etc/nixos/flake.nix symlink"
HOSTNAME=$(hostname)
NIX_DARWIN_HOME="/var/lib/git/nxmatic/nix-darwin-home"
NIXOS_FLAKE_SOURCE="${NIX_DARWIN_HOME}/hosts/${HOSTNAME}/flake.nix"
DISKO_NIX="${NIX_DARWIN_HOME}/modules/nixos/disko.nix"
if [ ! -e "/etc/nixos/flake.nix" ]; then
  if [ -f "${NIXOS_FLAKE_SOURCE}" ]; then
    mkdir -p /etc/nixos
    ln -fs "${NIXOS_FLAKE_SOURCE}" /etc/nixos/
    : "→ linked ${NIXOS_FLAKE_SOURCE} to /etc/nixos"
  else
    : "→ WARNING: host flake not found in ${NIXOS_FLAKE_SOURCE}"
  fi
fi

: "→ booting the ZFS based system (nixos-rebuild boot)"
if [ -n "${NIXOS_INSTALL_BOOTLOADER:-}" ]; then
  : "→ clearing inherited NIXOS_INSTALL_BOOTLOADER for runtime rebuild"
fi
env -u NIXOS_INSTALL_BOOTLOADER nixos-rebuild boot || : "→ WARNING: nixos-rebuild boot failed (continuing)"

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

: "→ bootstrap complete (reboot manually if desired)"
