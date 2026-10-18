# ndh-ceremony-vm: the runner of the root's ceremony VM on an operator seat (docs/root-ceremony.adoc), its argv
# fixed, the VM built by revision from modules/nixos/ceremony-vm.nix.
{ pkgs, ceremony }:
let
  inherit (pkgs) lib;
  c = ceremony.config;
in
pkgs.writeShellApplication {
  name = "ndh-ceremony-vm";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnused
    pkgs.mtools
  ];
  text = ''
    qemu=${pkgs.qemu}/bin/qemu-system-aarch64
    kernel=${c.system.build.kernel}/${c.system.boot.loader.kernelFile}
    initrd=${c.system.build.netbootRamdisk}/initrd
    init=${c.system.build.toplevel}/init
    params=${lib.escapeShellArg (toString c.boot.kernelParams)}
  ''
  + builtins.readFile ./ndh-ceremony-vm.sh;
}
