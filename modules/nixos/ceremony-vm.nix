{
  lib,
  pkgs,
  modulesPath,
  ...
}:
# The seedmatic root's ceremony VM (roles × keys ⑧, docs/root-ceremony.adoc): a netboot system, so the root is a
# tmpfs and the store a squashfs in the initrd, both in RAM, with no disk of its own. It has no network service
# and runs no daemon that listens; the runner (modules/darwin/ceremony-vm.d) gives it no network device at all.
# Two drives only: the operator's IN (read-only) and OUT, both vfat so the Mac can write and read them.
{
  imports = [ "${modulesPath}/installer/netboot/netboot.nix" ];

  system.stateVersion = "26.05";
  networking = {
    hostName = "ceremony";
    useDHCP = false;
    dhcpcd.enable = false;
    wireless.enable = false;
  };
  systemd.network.enable = false;
  services.openssh.enable = false;
  services.timesyncd.enable = false;
  nix.enable = false;
  documentation.enable = false;

  boot.kernelParams = [ "console=ttyAMA0" ];
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
  ];
  boot.supportedFilesystems = [ "vfat" ];
  fileSystems."/ceremony/in" = {
    device = "/dev/vda";
    fsType = "vfat";
    options = [
      "ro"
      "nofail"
    ];
  };
  fileSystems."/ceremony/out" = {
    device = "/dev/vdb";
    fsType = "vfat";
    options = [
      "nofail"
      "umask=077"
    ];
  };

  # The operator at the serial console is root; the VM lives minutes and holds nothing once powered off.
  services.getty.autologinUser = "root";
  environment.systemPackages = [
    (pkgs.callPackage ../.common.d/root-ceremony.d/package.nix { })
    (pkgs.callPackage ../.common.d/root-attest.d/package.nix { })
    pkgs.gnupg
    pkgs.openssl
  ];
}
