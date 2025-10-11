#!/usr/bin/env bash
# bootstrap-zfs: prepare and configure ZFS-based NixOS system inside Lima guest
# - Links existing nix-darwin-home working copy (preferred) into /var/lib/nixos/config
# - Ensures /etc/nixos/flake.nix points to host-specific flake
# - Optionally invokes lima-nixos-configuration service (idempotent)
# - Runs nixos-rebuild boot, disko (format+mount), converts mountpoints to legacy, exports pools
# Logging uses colon-prefixed no-op commands for concise, structured journal lines

set -euo pipefail

: "→ ensuring NixOS config working copy linked"
if [ ! -e /var/lib/nixos/config ]; then
  mkdir -p /var/lib/nixos
  USERNAME=$(id -un)
  HOSTNAME=$(hostname)
  CANDIDATES=()
  [ -n "${LIMA_NIXOS_CONFIG_PATH:-}" ] && CANDIDATES+=("$LIMA_NIXOS_CONFIG_PATH")
  CANDIDATES+=("/Users/$USERNAME/Gits/nxmatic/nix-darwin-home")
  CANDIDATES+=("/home/$USERNAME/Gits/nxmatic/nix-darwin-home")
  for cand in "${CANDIDATES[@]}"; do
    [ -z "$cand" ] && continue
    if [ -f "$cand/hosts/$HOSTNAME/flake.nix" ]; then
      ln -sfn "$cand" /var/lib/nixos/config
      : "→ linked /var/lib/nixos/config -> $cand"
      break
    fi
  done
  if [ ! -e /var/lib/nixos/config ]; then
    : "→ no existing working copy found; will attempt lima-nixos-configuration service"
  fi
fi

: "→ activating lima-nixos-configuration service (idempotent)"
if systemctl list-unit-files | grep -q '^lima-nixos-configuration.service'; then
  systemctl start lima-nixos-configuration.service || true
fi

: "→ ensuring /etc/nixos/flake.nix symlink"
HOSTNAME=$(hostname)
if [ ! -e /etc/nixos/flake.nix ]; then
  if [ -f "/var/lib/nixos/config/hosts/$HOSTNAME/flake.nix" ]; then
    mkdir -p /etc/nixos
    ln -fs "/var/lib/nixos/config/hosts/$HOSTNAME/flake.nix" /etc/nixos/flake.nix
    : "→ linked /etc/nixos/flake.nix"
  else
    : "→ WARNING: host flake not found in /var/lib/nixos/config/hosts/$HOSTNAME/flake.nix"
  fi
fi

: "→ booting the ZFS based system (nixos-rebuild boot)"
nixos-rebuild boot || : "→ WARNING: nixos-rebuild boot failed (continuing)"

: "→ running disko configuration"
if [ -f /var/lib/nixos/config/modules/nixos/disko.nix ]; then
  disko --mode format,mount /var/lib/nixos/config/modules/nixos/disko.nix || : "→ WARNING: disko failed"
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
