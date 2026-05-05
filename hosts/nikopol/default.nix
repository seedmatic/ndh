let
  hardware = import ./hardware.nix;

  halfRamMiB = hardware.ramGiB * 512; # half of physical RAM in MiB

  hostProfile = {
    hostName = "nikopol";
    form = "vm";
    nixosBootLoader = "systemd-boot";
    nixosBootstrapDebug = false;
    # raidz1 usable = 2 × vdev: 12 GiB → vdev = 6144 MiB → zpoolVdevDiskSizeMiB = 6658M
    nixosDiskImageSizeGiB = 12;
    # nixos-install inside nested QEMU only uses ~3.5 GiB RSS; default 8 GiB is sufficient.
  };

  darwinProfile = {
    knownNetworkServices = hardware.knownNetworkServices;
    wallpaperImage = ./assets.d/Scavengers-Reign.jpg;
  };

  profileModule = import ./profile.nix { inherit hostProfile darwinProfile; };
  darwinModule = import ./darwin.nix { inherit halfRamMiB; };
  nixosModule = import ./nixos.nix;
in
{
  inherit hostProfile profileModule;
  darwinExtraModules = [ darwinModule ];
  nixosExtraModules = [ nixosModule ];
}
