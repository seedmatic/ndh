{
  description = "nix system configurations for bioskop";

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
        hostName = "bioskop";
        tailnet = { };
      };
      darwinProfile = {
        # Align with actual macOS service names to avoid networksetup errors
        knownNetworkServices = [
          "Thunderbolt Ethernet Slot 1"
          "Ethernet"
          "USB 10/100/1000 LAN"
          "Wi-Fi"
          "Tailscale"
          "Tailscale 2"
          "Thunderbolt Bridge"
        ];
        wallpaperImage = ./assets/WallPaper.jpg;
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
            # Teleport removed - using Headscale for internal network
          ];
          config = {
            profile = {
              host = {
                hostName = lib.mkDefault hostProfile.hostName;
                tailnet = hostProfile.tailnet;
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
            };

            # Enable rescue tooling for this host (default is off)
            # rescue.enable = true;

            # Headscale client - connects to server in Lima VM
            # Note: Server must be deployed first at 192.168.5.10:8080
            services.headscale-client = {
              enable = true;
              serverUrl = "http://192.168.5.10:8080";
              enableSSH = true;
            };

            # Enable cross-host distributed builds (Darwin only)
            services.crossHostBuilders.enable = true;

            # Sign locally produced store paths so peer hosts can trust nix copy --from ssh-ng://bioskop
            nix.settings = lib.mkMerge [
              {
                trusted-users = [
                  "builder"
                ];
              }
              (lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
                secret-key-files = [ "/etc/nix/bioskop-cache.key" ];
              })
            ];

            # Bootstrap cache signing key on NixOS guests if missing.
            # The secret key remains local at /etc/nix and is not stored in the Nix store.
            system.activationScripts.ensureBioskopCacheKey = lib.mkIf pkgs.stdenv.hostPlatform.isLinux ''
              if [ ! -s /etc/nix/bioskop-cache.key ] || [ ! -s /etc/nix/bioskop-cache.pub ]; then
                install -d -m 0755 /etc/nix
                ${pkgs.nix}/bin/nix-store --generate-binary-cache-key \
                  bioskop-cache \
                  /etc/nix/bioskop-cache.key \
                  /etc/nix/bioskop-cache.pub
                chmod 600 /etc/nix/bioskop-cache.key
                chmod 644 /etc/nix/bioskop-cache.pub
              fi
            '';
          };
        };

      # Darwin-specific module for network bonding and monitoring
      darwinModule =
        { config, lib, ... }:
        {
          config = {
            networking.vlan = {
              enable = true;
              id = 2;
              addressPrefix = "192.168.2";
              parentInterface = "en9";
            };

            # Network bonding configuration (Darwin only)
            # Combines en0 (built-in) and en8 (OWC hub) for ~1.8 Gbps aggregate bandwidth
            networking.bond = {
              enable = false; # Enable when needed
              interfaces = [
                "en0"
                "en8"
              ];
              mode = "static"; # Static LAG without LACP protocol
            };

          };
        };
    in
    nix-darwin-home.mkHostOutputs {
      inherit hostProfile profileModule;
      darwinExtraModules = [ darwinModule ];
    };
}
