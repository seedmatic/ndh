let
  hardware = import ./hardware.nix;

  halfRamMiB = hardware.ramGiB * 512; # half of physical RAM in MiB

  hostProfile = {
    hostName = "nikopol";
    form = "vm";
    nixosBootLoader = "systemd-boot";
    nixosBootstrapDebug = false;
    nixosDiskImageVmCpuCores = 6; # 6 vCPUs for nested QEMU (nerd-nixos has 8 total)
    nixosDiskImageVmMemSizeMiB = 12288; # 12 GB for nested QEMU (nerd-nixos has 32 GB)
  };

  darwinProfile = {
    knownNetworkServices = hardware.knownNetworkServices;
    wallpaperImage = ./assets.d/Scavengers-Reign.jpg;
  };

  profileModule = import ./profile.nix { inherit hostProfile darwinProfile; };
  darwinModule = import ./darwin.nix { inherit halfRamMiB; };
  nixosModule = import ./nixos.nix;
  developerToolsModule = import ./modules/darwin/developer-tools.nix;
in
{
  inherit hostProfile profileModule;
  darwinExtraModules = [
    darwinModule
    developerToolsModule
  ];
  nixosExtraModules = [ nixosModule ];
}
