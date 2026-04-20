# @codebase
# Shared bringup image helper logic used by raw and ZFS bringup image builders.
{
  lib,
  pkgs,
  qemuFallbackInVm ? true,
  # When true, attach a basic slirp user-mode network to the nested QEMU guest.
  # No port-forwards are set up; use the serial console socket for introspection.
  nestedQemuNetworkEnable ? true,
}:
let
  qemuCommon = import (pkgs.path + "/nixos/lib/qemu-common.nix") {
    inherit lib pkgs;
  };

  defaultQemuCommand = qemuCommon.qemuBinary pkgs.qemu_kvm;

  fallbackQemuCommand =
    builtins.replaceStrings [ "accel=kvm:tcg" "accel=hvf:tcg" ] [ "accel=tcg" "accel=tcg" ]
      defaultQemuCommand;

  vmToolsBase =
    if qemuFallbackInVm then
      pkgs.vmTools.override {
        customQemu = fallbackQemuCommand;
      }
    else
      pkgs.vmTools;

  # Basic slirp network — gives DHCP and internet access to the guest.
  # No SSH/monit port-forwards: use the serial console socket instead.
  nestedQemuNetOpts =
    if nestedQemuNetworkEnable then
      "-netdev user,id=ndhnet0 -device virtio-net-pci,netdev=ndhnet0"
    else
      "";
in
{
  inherit vmToolsBase nestedQemuNetOpts;
}
