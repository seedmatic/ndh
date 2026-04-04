{
  description = "nix system configurations for nikopol";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://nxmatic.cachix.org"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nxmatic.cachix.org-1:oWogvXdam3gTxKzPZCDqq8khybQpqRdNpQQrKG3r4xM="
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
        nixosImageMode = "bootstrap";
        nixosBootLoader = "systemd-boot";
        bootstrapDebug = true;
        enableHomeManager = false;
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
          lib,
          config,
          ...
        }:
        {
          imports = [
            (
              import ../.common.d/host-common.nix {
                inherit hostProfile darwinProfile;
                headscaleServerUrl = "http://192.168.1.193:8080";
                forceRemoteBuilds = true;
                preferredBuilderHosts = [ "bioskop" ];
              }
            )
          ];
          config = {

            # Keep experiment/bootstrap mode until boot/login validation is complete.
            # This avoids stage-2 panic when /etc/sops/age/keys.txt is not yet provisioned.
            nxmatic.sopsAgeKeyBootstrap.phase = "bootstrap";
            nxmatic.sopsAgeKeyBootstrap.nixosHostKeyImport.candidates = [
              # Preferred: key delivered via Lima cidata payload.
              "/mnt/lima-cidata/.sops.d/keys.txt"
              # Host-mounted fallback: ~/Private/sops:age:keys.txt on Darwin host.
              "/Users/nxmatic/.config/sops/age/keys.txt"
            ];

            # Safety valve while exercising fresh SSH/runtime-secret changes.
            opensshPolicy.passwordAuthentication = true;

            nix.settings = {
              trusted-users = [
                "root"
                "nxmatic"
              ];
            };
          };
        };

      darwinModule =
        { lib, ... }:
        {
          config = {
            profile.user.home = lib.mkForce (builtins.toPath "/Volumes/user-home");

            services.nxmaticCachixWatchStore = {
              enable = true;
              sopsEncryptedTokenFile = ../../.secrets;
            };

            networking.vlan = {
              enable = true;
              id = 2;
              addressPrefix = "192.168.2";
              parentInterface = "en0";
            };
          };
        };

      nixosModule =
        {
          config,
          lib,
          hostProfile ? { },
          ...
        }:
        let
          # Canonical source-of-truth network values from rke2lab netplan catalog (@codebase)
          netplanCatalog = config._module.specialArgs.catalog.networks.rke2labNetplan;
          clusterNetwork = netplanCatalog.clusters.nikopol;
          bootstrapMode =
            if hostProfile ? nixosImageMode && hostProfile.nixosImageMode != null then
              hostProfile.nixosImageMode == "bootstrap"
            else
              false;
        in
        {
          config =
            {
              profile.user.home = lib.mkForce "/home/${config.profile.user.name}";
            }
            // (lib.optionalAttrs (!bootstrapMode) {
              services.nxmaticCachixWatchStore.sopsEncryptedTokenFile = ../../.secrets;
            })
            // (lib.optionalAttrs (!bootstrapMode) {
              networking.vlan = {
                enable = true;
                id = 2;
                addressPrefix = "192.168.2";
                parentInterface = "vmlan0";
                addressSourceInterface = "lan-br";
              };
            })
            // (lib.optionalAttrs (!bootstrapMode) {
              # Expose system D-Bus over vmnet gateway for lab-only remote control/testing.
              services.dbusTcpSystemBus = {
                enable = true;
                bindAddress = clusterNetwork.gateway;
                port = 12434;
                openFirewall = true;
                insecureAllowAnonymous = true;
              };
            });
        };
    in
    nix-darwin-home.mkHostOutputs {
      inherit hostProfile profileModule;
      darwinExtraModules = [ darwinModule ];
      nixosExtraModules = [ nixosModule ];
    };
}
