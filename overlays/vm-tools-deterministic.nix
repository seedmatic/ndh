inputs: final: prev:
let
  qemuCommon = import (prev.path + "/nixos/lib/qemu-common.nix") {
    lib = prev.lib;
    pkgs = prev;
  };

  qemuRawDriveWrapper = prev.writeShellScriptBin "qemu-system-aarch64-raw-drive-wrapper" (
    builtins.replaceStrings [ "@qemuBin@" ] [ "${prev.qemu_kvm}/bin/qemu-system-aarch64" ] (
      builtins.readFile ./vm-tools-deterministic.sh
    )
  );

  defaultQemuCommand = qemuCommon.qemuBinary prev.qemu_kvm;
  wrappedQemuBinaryCommand =
    builtins.replaceStrings
      [ "${prev.qemu_kvm}/bin/qemu-system-aarch64" ]
      [ "${qemuRawDriveWrapper}/bin/qemu-system-aarch64-raw-drive-wrapper" ]
      defaultQemuCommand;
  wrappedQemuCommand =
    builtins.replaceStrings [ "accel=kvm:tcg" "accel=hvf:tcg" ] [ "accel=tcg" "accel=tcg" ]
      wrappedQemuBinaryCommand;
in
{
  vmTools = prev.vmTools.override {
    customQemu = wrappedQemuCommand;
  };
}
