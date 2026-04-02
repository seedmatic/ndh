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
          options,
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

            # Two-phase SOPS key provisioning:
            # phase 2 enforces existing key presence.
            nxmatic.sopsAgeKeyBootstrap.phase = "enforce";

            # Safety valve while exercising fresh SSH/runtime-secret changes.
            opensshPolicy.passwordAuthentication = true;

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
          ...
        }:
        let
          # Canonical source-of-truth network values from rke2lab netplan catalog (@codebase)
          netplanCatalog = config._module.specialArgs.catalog.networks.rke2labNetplan;
          clusterNetwork = netplanCatalog.clusters.nikopol;
          effectiveHostProfile =
            if config._module.specialArgs ? hostProfile then config._module.specialArgs.hostProfile else hostProfile;
          bootstrapMode =
            if effectiveHostProfile ? nixosImageMode && effectiveHostProfile.nixosImageMode != null then
              effectiveHostProfile.nixosImageMode == "bootstrap"
            else
              false;
        in
        {
          config = lib.mkIf (!bootstrapMode) {
            services.nxmaticCachixWatchStore.sopsEncryptedTokenFile = ../../.secrets;

            networking.vlan = {
              enable = true;
              id = 2;
              addressPrefix = "192.168.2";
              parentInterface = "vmlan0";
              addressSourceInterface = "lan-br";
            };

            # Expose system D-Bus over vmnet gateway for lab-only remote control/testing.
            services.dbusTcpSystemBus = {
              enable = true;
              bindAddress = clusterNetwork.gateway;
              port = 12434;
              openFirewall = true;
              insecureAllowAnonymous = true;
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
