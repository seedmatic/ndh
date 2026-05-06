let
  hardware = import ./hardware.nix;

  halfRamMiB = hardware.ramGiB * 512; # half of physical RAM in MiB

  hostProfile = {
    hostName = "bioskop";
    vmProvider = "tart";
    nixosBootLoader = "systemd-boot";
    nixosBootstrapDebug = false;
    form = "baremetal";
    # Nested QEMU build VM memory: 12 GiB gives the guest ZFS ARC ~8 GiB (2/3),
    # leaving ~12 GiB for the linux-builder host itself (OS + ZFS ARC + QEMU overhead).
    # Requires linux-builder vmMemoryMiB ≥ 24576 (set in inventory/default.nix).
    nixosDiskImageVmMemSizeMiB = 12288;
  };

  darwinProfile = {
    knownNetworkServices = hardware.knownNetworkServices;
    wallpaperImage = ./assets.d/WallPaper.jpg;
  };

  profileModule = import ./profile.nix { inherit hostProfile darwinProfile; };
  darwinModule = import ./darwin.nix { inherit halfRamMiB; };
  nixosModule = import ./nixos.nix;
in
{
  inherit hostProfile profileModule;
  darwinExtraModules = [ darwinModule ];
  nixosExtraModules = [ nixosModule ];
  withBringupImages = false;
}
