# Single source of truth for initrd emergency/rescue shell configuration.
# Applies the forensic toolset from initrd-emergency-tools.nix and configures
# emergency/rescue services, journald for boot troubleshooting.
#
# Import this module in any NixOS config that needs emergency shell capabilities.
{ lib, pkgs, ... }:
let
  initrdEmergencyTools = import ./initrd-emergency-tools.nix pkgs;
in
{
  boot.initrd.systemd = {
    # Enable emergency shell access on boot failures
    emergencyAccess = true;

    # Root discovery mode: use fstab for ZFS root
    # gpt-auto (Discoverable Partitions Spec) causes 90s timeout on ZFS roots
    # waiting for /dev/gpt-auto-root that never appears. ZFS uses zfs-import.
    root = lib.mkForce "fstab";

    # Emergency tools: grep, sed, awk, sgdisk, lsblk, zdb, etc.
    # Canonical list defined in ./initrd-emergency-tools.nix.
    # storePaths embeds the closures so /bin symlinks are not dangling when
    # /nix/store is not yet mounted (early-boot emergency shell).
    extraBin = initrdEmergencyTools.extraBin;
    storePaths = initrdEmergencyTools.storePaths;
    services = {
      emergency.environment.SYSTEMD_SULOGIN_FORCE = "1";
      rescue.environment.SYSTEMD_SULOGIN_FORCE = "1";
      # Reduce initrd dependency-noise from kbd tooling (setfont/loadkeys)
      # in headless/serial bringup flows.
      "systemd-vconsole-setup".enable = lib.mkForce false;
    };
    # Forward journald to console for emergency shell visibility
    contents."/etc/systemd/journald.conf".text = ''
      [Journal]
      ForwardToConsole=yes
      MaxLevelConsole=debug
    '';
  };
}
