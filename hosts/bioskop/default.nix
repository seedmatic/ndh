let
  hardware = import ./hardware.nix;

  halfRamMiB = hardware.ramGiB * 512; # half of physical RAM in MiB

  hostProfile = {
    hostName = "bioskop";
    nixosBootLoader = "systemd-boot";
    nixosBootstrapDebug = false;
    # Bringup pool sizing: df on previous run showed ~6.8 GiB final usage
    # (9193.5 MiB NAR data compressed at ~1.4:1 by ZFS lz4).
    # 10 GiB gives raidz1 usable = 2 × 5120 MiB = 10 GiB → 68% usage.
    # Host build artifacts: 4 × 5634 MiB ≈ 22 GiB on nerd-nixos ZFS pool.
    # After first boot, zpool-init expands vdevs to full vmDataDiskSizeGiB.
    nixosDiskImageSizeGiB = 10;
    # nixos-install inside nested QEMU only uses ~3.5 GiB RSS; default 8 GiB is sufficient.
    # Keeping this unset lets the default (8192) apply — avoids locking 24+ GiB host RAM.
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
}
