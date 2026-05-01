# Single source of truth for the forensic/disk-recovery toolset that must be
# present in the initrd emergency shell across ALL NixOS configurations.
#
# Returns an attrset suitable for `boot.initrd.systemd.extraBin`.
# The same packages are also referenced in bringup-zfs-disk-image.nix to keep
# the bringup shell PATH consistent with what is available in stage-1 recovery.
pkgs: {
  sgdisk = "${pkgs.gptfdisk}/bin/sgdisk"; # GPT partition editing
  hexdump = "${pkgs.util-linux}/bin/hexdump"; # raw binary inspection
  lsblk = "${pkgs.util-linux}/bin/lsblk"; # block device enumeration
  blkid = "${pkgs.util-linux}/bin/blkid"; # filesystem/partition UUID probing
  partx = "${pkgs.util-linux}/bin/partx"; # kernel partition table refresh
  fdisk = "${pkgs.util-linux}/bin/fdisk"; # MBR/GPT editing fallback
  zdb = "${pkgs.zfs}/bin/zdb"; # ZFS pool low-level diagnostics
  xterm = "${pkgs.xterm}/bin/xterm"; # provides `resize` for socat terminal sizing
}
