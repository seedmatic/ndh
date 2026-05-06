# Bringup xchg mount — ensures /tmp/xchg is available in nested QEMU
#
# When running in bringup mode (inside the nested QEMU during disk image creation),
# this module mounts the xchg directory shared via virtio-9p from the host.
# The xchg directory is used to pass:
#   - pause.lock for inspection pauses
#   - boot-size-hint.yaml with boot partition metadata
#   - zfs-nixos-install-observe.yaml with install observability data
#   - builder-observe.yaml with builder-side metrics
{
  config,
  lib,
  ndh,
  ...
}:
with lib;
let
  ndhContext = ndh.context;
  generationMode = ndhContext.generationMode;
  bringupMode = generationMode == "bringup";
in
{
  config = mkIf bringupMode {
    # Ensure 9p kernel modules are available
    boot.kernelModules = [
      "9p"
      "9pnet_virtio"
      "virtio_pci"
    ];

    # Mount xchg via virtio-9p (shared from host with mount_tag=xchg)
    fileSystems."/tmp/xchg" = {
      device = "xchg";
      fsType = "9p";
      options = [
        "trans=virtio"
        "version=9p2000.L"
        "msize=104857600" # 100MB max message size for better performance
      ];
      neededForBoot = false; # Not needed in initrd, mount after boot
    };

    # Ensure /tmp/xchg directory exists before mounting
    systemd.tmpfiles.rules = [
      "d /tmp/xchg 0755 root root -"
    ];
  };
}
