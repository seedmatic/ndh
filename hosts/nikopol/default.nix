let
  hardware = import ./hardware.nix;

  halfRamMiB = hardware.ramGiB * 512; # half of physical RAM in MiB

  hostProfile = {
    hostName = "nikopol";
    form = "vm";
    nixosBootLoader = "systemd-boot";
    nixosBootstrapDebug = false;
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
