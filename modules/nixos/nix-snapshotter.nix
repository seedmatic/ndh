{ config, pkgs, nix-snapshotter, ... }:

{
  imports = [ nix-snapshotter.nixosModules.default ];

  nixpkgs.overlays = [ nix-snapshotter.overlays.default ];

  services.nix-snapshotter.enable = true;

  virtualisation.containerd = {
    enable = true;
    nixSnapshotterIntegration = true;
  };

  environment.systemPackages = with pkgs; [
    nerdctl
  ];
}