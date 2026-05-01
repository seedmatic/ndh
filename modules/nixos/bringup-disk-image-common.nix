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

  # Wrap virtiofsd so the /nix/store mount gets UID/GID mapping:
  #   --uid-map :0:<host-uid>:1: → host build-user uid appears as root in guest
  #   --gid-map :0:<host-gid>:1: → host build-user gid appears as root in guest
  # The xchg mount is left unmapped (only carries exit codes).
  virtiofsdWithStoreUidMap = pkgs.writeShellScriptBin "virtiofsd" ''
    is_store_mount=0
    for arg in "$@"; do
      [[ "$arg" == "${builtins.storeDir}" ]] && is_store_mount=1 && break
    done
    if [[ "$is_store_mount" == 1 ]]; then
      exec ${lib.getExe pkgs.virtiofsd} \
        --uid-map ":0:$(id -u):1:" \
        --gid-map ":0:$(id -g):1:" \
        "$@"
    fi
    exec ${lib.getExe pkgs.virtiofsd} "$@"
  '';

  # Extend pkgs so vmTools picks up our wrapper — pkgs is a direct vmTools parameter.
  pkgsWithMappedVirtiofsd = pkgs.extend (_: _: { virtiofsd = virtiofsdWithStoreUidMap; });

  vmToolsBase =
    if qemuFallbackInVm then
      pkgsWithMappedVirtiofsd.vmTools.override {
        customQemu = fallbackQemuCommand;
      }
    else
      pkgsWithMappedVirtiofsd.vmTools;

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
