# Canonical ZFS disk → pool membership map for the nerd-nixos Lima VM.
# Single source of truth consumed by:
#   - modules/darwin/lima-config.nix       (additionalDisks labels)
#   - modules/nixos/zfs-disko-config.nix   (pool-member disk definitions)
#   - modules/nixos/bringup-zfs-disk-image.nix (generated *.img disk set)
#
# Each entry:
#   disk  — Lima disk suffix (appended after "${limaVm}-", e.g. "tank1" → "nerd-nixos-tank1")
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
