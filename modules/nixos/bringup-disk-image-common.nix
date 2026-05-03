# @codebase
# Shared bringup image helper logic used by raw and ZFS bringup image builders.
{
  lib,
  pkgs,
  # When true, attach a basic slirp user-mode network to the nested QEMU guest.
  # No port-forwards are set up; use the serial console socket for introspection.
  nestedQemuNetworkEnable ? true,
}:
let
  qemuCommon = import (pkgs.path + "/nixos/lib/qemu-common.nix") {
    inherit lib pkgs;
  };

  qemuBin = "${pkgs.qemu_kvm}/bin/qemu-system-aarch64";

  # Wrapper that detects /dev/kvm at build time and selects the right accelerator.
  # - On linux-builder (macOS NixOS builder): no /dev/kvm → accel=tcg (software)
  # - On nerd-nixos (Tart VM with nested virt): /dev/kvm present → accel=kvm:tcg
  # vmTools embeds customQemu verbatim into a shell script; any args it appends
  # become positional args ($@) to this wrapper.
  kvmDetectQemu = pkgs.writeShellScript "qemu-kvm-detect" ''
    if [ -e /dev/kvm ]; then
      accel="kvm:tcg"
    else
      accel="tcg"
    fi
    exec ${qemuBin} -machine virt,gic-version=max,accel=$accel -cpu max "$@"
  '';

  vmToolsBase = pkgs.vmTools.override {
    customQemu = "${kvmDetectQemu}";
  };

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
