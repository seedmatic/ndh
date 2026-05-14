# Canonical ZFS disk partition layout constants for nerd-nixos bringup.
#
# Single source of truth consumed by:
#   - zfs-disko-config.nix  (partition definitions for disko bringup build)
#   - bringup-zfs-disk-image.nix  (disk image builder, passes to disko)
#   - modules/nixos/zfs.nix  (systemd-repart options, grow-on-boot)
#
# Disk layout (per tank/recover data disk):
#   ┌───────────────────────────────────────────────────────┐
#   │ GPT header  1 MiB                                     │
#   │ ESP         512 MiB  type: EF00  label: esp-<disk>    │
#   │ ZFS vdev    rest     type: BF01  label: <disk>        │
#   └───────────────────────────────────────────────────────┘
{
  # Boot disk (vda) — EFI-only, no ZFS partition.
  bootDiskSizeMiB = 600; # 512 MiB ESP + GPT overhead

  # Per pool-disk partition layout
  espStartMiB = 1;
  espSizeMiB = 512;
  # zfsStartMiB is derived: espStartMiB + espSizeMiB + 1 (alignment gap)

  # Solaris/ZFS GPT type GUID — disko shorthand "BF01".
  # Used in both disko partition type and systemd-repart Type= field.
  zfsPartitionTypeGuid = "6A898CC3-1DD2-11B2-99A6-080020736631";
}
