let
  hardware = import ./hardware.nix;

  halfRamMiB = hardware.ramGiB * 512; # half of physical RAM in MiB

  hostProfile = {
    hostName = "bioskop";
    nixosBootLoader = "systemd-boot";
    nixosBootstrapDebug = false;
    form = "bare-metal";
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
