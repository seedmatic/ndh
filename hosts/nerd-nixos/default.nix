let
  hostProfile = {
    hostName = "nerd-nixos";
    hostAlias = "nerd-nixos";
    form = "vm";
    vmProvider = "tart";
    nixosBootLoader = "systemd-boot";
    nixosBringupRootFs = "zfs";
    nixosBootstrapDebug = false;
  };

  profileModule = import ./profile.nix { inherit hostProfile; };
  nixosModule = import ./nixos.nix;
in
{
  inherit hostProfile profileModule;
  darwinExtraModules = [ ];
  nixosExtraModules = [ nixosModule ];
}
