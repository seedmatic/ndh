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
        wallpaperImage = ./assets/Scavengers-Reign.jpg;
      };

      profileModule =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        {
          imports = [
            ../../profiles/committed.nix
          ];
          config = {
            profile = {
              host = {
                hostName = lib.mkDefault hostProfile.hostName;
                tailnet = hostProfile.tailnet;
                forceRemoteBuilds = true;
                preferredBuilderHosts = [ "bioskop" ];
              }
              // (
                if hostProfile ? hostAlias then
                  {
                    hostAlias = lib.mkDefault hostProfile.hostAlias;
                  }
                else
                  { }
              );
              darwin = darwinProfile;
              user.home = lib.mkForce (builtins.toPath "/Volumes/user-home");
            };

            # Enable cross-host builders so ssh_config.d drop-ins are installed
            services.crossHostBuilders.enable = true;

            services.headscale-client = {
              enable = true;
              serverUrl = "http://192.168.1.193:8080";
              enableSSH = true;
            };

            # Trust bioskop local signing key for remote closure imports (nix copy --from ssh-ng://nxmatic@bioskop)
            nix.settings = {
              extra-trusted-public-keys = [
                "bioskop-cache:H6oZXzgzujE4+saXVe6LDfzBRUUVCgPYYTFLoxK7IuE="
              ];
              trusted-users = [
                "root"
                "nxmatic"
              ];
            };
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
