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
    wallpaperImage = ./assets.d/WallPaper.jpg;
  };

  profileModule =
    {
      config,
      ...
    }:
    {
      imports = [
        (import ../host-common.nix {
          inherit hostProfile darwinProfile;
          headscaleServerUrl = "http://192.168.5.10:8080";
        })
        # Teleport removed - using Headscale for internal network
      ];
      config = {
        # Enable rescue tooling for this host (default is off)
        # rescue.enable = true;

        # Sign locally produced store paths so peer hosts can trust nix copy --from ssh-ng://bioskop
        nix.settings.trusted-users = [
          "builder"
        ];
      };
    };

  darwinModule =
    { config, lib, ... }:
    let
      # Canonical source-of-truth network values from rke2lab netplan catalog (@codebase)
      netplanCatalog = config._module.specialArgs.catalog.networks.rke2labNetplan;
      clusterNetwork = netplanCatalog.clusters.bioskop;
    in
    {
      config = {
        # Two-phase SOPS age key provisioning on Darwin:
        # phase 2 (enforce): key must already exist.
        nxmatic.sopsAgeKeyBootstrap = {
          phase = "enforce";
          darwinSystemWideKey = true;
        };
        sops.age.keyFile = "/etc/sops/age/keys.txt";

        services.nxmaticCachixWatchStore = {
          enable = true;
          sopsEncryptedTokenFile = ../../.secrets;
        };

        networking.vlan = {
          enable = false; # Temporarily disabled: VLAN 2 currently causes local resolution/routing issues.
          id = 2;
          addressPrefix = "192.168.2";
          parentInterface = "en9";
        };

        networking.staticRoutes = {
          enable = true;
          routes = [
            {
              kind = "net";
              destination = clusterNetwork.cidr;
              gateway = "192.168.1.130";
              interface = "en9";
            }
          ];
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

  nixosModule =
    {
      config,
      pkgs,
      lib,
      options,
      ...
    }:
    let
      # Canonical source-of-truth network values from rke2lab netplan catalog (@codebase)
      netplanCatalog = config._module.specialArgs.catalog.networks.rke2labNetplan;
      clusterNetwork = netplanCatalog.clusters.bioskop;
    in
    {
      config = {
        services.nxmaticCachixWatchStore.sopsEncryptedTokenFile = ../../.secrets;

        # Sign locally produced store paths so peer hosts can trust nix copy --from ssh-ng://bioskop
        nix.settings.secret-key-files = [ "/etc/nix/bioskop-cache.key" ];

        # Bootstrap cache signing key on NixOS guests if missing.
        # The secret key remains local at /etc/nix and is not stored in the Nix store.
        system.activationScripts.ensureBioskopCacheKey = ''
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

      }
      // (lib.optionalAttrs (options ? services && options.services ? dbusTcpSystemBus) {
        # Expose system D-Bus over the vmnet-facing address (not loopback)
        # for lab-only remote control/testing traffic (when module is available).
        services.dbusTcpSystemBus = {
          enable = true;
          # Netplan catalog-derived vmnet gateway for bioskop cluster slice.
          bindAddress = clusterNetwork.gateway;
          port = 12434;
          openFirewall = true;
          insecureAllowAnonymous = true;
        };
      });
    };
in
{
  inherit hostProfile profileModule;
  darwinExtraModules = [ darwinModule ];
  nixosExtraModules = [ nixosModule ];
}
