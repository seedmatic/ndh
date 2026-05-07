# ZFS boot configuration shared across NixOS systems.
# Configures ZFS support, pool import behavior, and device discovery.
{ lib, ... }:
{
  # Essential ZFS support for pool operations
  boot.supportedFilesystems = [ "zfs" ];

  # Force import even if pool appears in use (safe for single-system VMs)
  boot.zfs.forceImportRoot = true;

  # Use /dev for device discovery in VZ/Tart VMs
  # virtio devices (/dev/vdb, /dev/vdc, etc.) don't have /dev/disk/by-id/ symlinks
  boot.zfs.devNodes = "/dev";

  # Import additional ZFS pools at boot (beyond root pool)
  boot.zfs.extraPools = [ "tank" "recover" ];
}
