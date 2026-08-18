# Canonical ZFS disk → pool membership map for the nerd-nixos VM.
# Single source of truth consumed by:
#   - modules/nixos/zfs-disko-config.nix   (pool-member disk definitions)
#   - modules/nixos/bringup-zfs-disk-image.nix (generated *.img disk set)
#
# Each entry:
#   disk  — disk suffix (appended after the VM name, e.g. "tank1" → "nerd-nixos-tank1")
#   pool  — ZFS pool the disk is a member of
[
  {
    disk = "tank1";
    pool = "tank";
  }
  {
    disk = "tank2";
    pool = "tank";
  }
  {
    disk = "tank3";
    pool = "tank";
  }
  {
    disk = "recover";
    pool = "recover";
  }
]
