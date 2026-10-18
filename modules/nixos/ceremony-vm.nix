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

  # `ndh-ceremony-vm --smoke` (🎛️'s check, no drive): print what the VM sees, then power off.
  systemd.services.ceremony-smoke = {
    description = "Show the ceremony VM's links and mounts, then power off";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionKernelCommandLine = "ceremony.smoke=1";
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "tty";
      TTYPath = "/dev/ttyAMA0";
    };
    path = [
      pkgs.gawk
      pkgs.iproute2
      pkgs.util-linux
    ];
    script = ''
      echo "[ceremony-smoke] links: $(ip -o link | awk -F': ' '{ print $2 }' | paste -sd' ')"
      echo "[ceremony-smoke] 9p or virtiofs mounts: $(findmnt -n -t 9p,virtiofs | wc -l)"
      echo "[ceremony-smoke] / is $(findmnt -n -o FSTYPE /)"
      echo "[ceremony-smoke] /ceremony/in mounted: $(findmnt -n /ceremony/in >/dev/null && echo yes || echo no)"
      systemctl poweroff
    '';
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
