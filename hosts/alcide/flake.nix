{
  description = "nix system configurations for nikopol";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://nxmatic.cachix.org"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nxmatic.cachix.org-1:huMghYiwDpPa1PMXHXK4G1Dp4QOZjgsNqxcjf/AjuJ0="
    ];
  };

  inputs = {
    nix-darwin-home.url = "path:../..";
  };

  outputs =
    { self, nix-darwin-home, ... }@inputs:
    let
      hostProfile = {
        hostName = "nikopol";
        tailnet = { };
      };
      darwinProfile = {
        knownNetworkServices = [
          "Wi-Fi"
          "Thunderbolt Ethernet"
        ];
      };

      profileModule =
        {
          lib,
          ...
        }:
        {
          imports = [
            (import ../.common.d/host-common.nix {
              inherit hostProfile darwinProfile;
              headscaleServerUrl = "http://192.168.1.193:8080";
              forceRemoteBuilds = true;
              preferredBuilderHosts = [ "bioskop" ];
            })
          ];
          config = {
            # Host-specific profile additions go here.
          };
        };

      darwinModule =
        { ... }:
        {
          config = {
            networking.vlan = {
              enable = true;
              id = 2;
              addressPrefix = "192.168.2";
              parentInterface = "en0";
            };
          };
        };

      nixosModule =
        { ... }:
        {
          config = {
            networking.vlan = {
              enable = true;
              id = 2;
              addressPrefix = "192.168.2";
              parentInterface = "vmlan0";
              addressSourceInterface = "lan-br";
            };
          };
        };
    in
    nix-darwin-home.mkHostOutputs {
      inherit hostProfile profileModule;
      darwinExtraModules = [ darwinModule ];
      nixosExtraModules = [ nixosModule ];
    };
}
