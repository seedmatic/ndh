let
  hostProfile = {
    hostName = "bioskop";
    nixosBootLoader = "systemd-boot";
    nixosBootstrapDebug = false;
    # Keep explicit host defaults for image-build VM resources.
    # These match canonical defaults from modules/nixos/outputs.nix.
    nixosDiskImageVmMemSizeMiB = 6144;
    # Capped at 4: nested KVM inside Tart VZ recommends ≤4 vCPUs.
    nixosDiskImageVmCpuCores = 4;
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
        # Enable rescue tooling for this host when needed (default is off)
        # rescue.enable = true;

        # Sign locally produced store paths so peer hosts can trust nix copy --from ssh-ng://bioskop
        nix.settings.trusted-users = [
          "builder"
        ];
      };
    };

  darwinModule =
    {
      config,
      lib,
      ndh,
      ...
    }:
    let
      ndhContext = ndh.context;
      # Canonical source-of-truth network values from rke2lab netplan catalog (@codebase)
      rke2labNetplan = ndhContext.catalog.netplan.rke2lab;
      clusterNetwork = rke2labNetplan.clusters.bioskop;
    in
    {
      config = {
        # Two-phase SOPS age key provisioning on Darwin:
        # phase 2 (enforce): key must already exist.
        ndh.sopsAgeKeyBootstrap = {
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
            "en9"
          ];
          mode = "static"; # Static LAG without LACP protocol
        };

        lima.configGenerator = {
          installMaterializerPackage = false;
          vmType = "qemu"; # Use QEMU for having a prompt in emergency mode, which is useful for debugging. VZ doesn't support interactive prompt on boot.
          sshLocalPort = 61022; # Fixed port so nix daemon can reach nerd-nixos as a remote builder.
          # vmMemoryMiB = 8192;
          # vmCpuCores = 6;
        };

        tart.configGenerator = {
          forceEnable = false;
          installMaterializerPackage = false;
          # Nested QEMU bringup needs 6 GiB inside the VM + guest OS overhead.
          # Keep at least 8 GiB so OOM killer doesn't kill the nested QEMU.
          vmMemoryMiB = 8192;
          vmRunBridgeInterface = "Thunderbolt Ethernet Slot 1";
          vmRunSerialBridgeEnable = true;
          vmRunSerialBridgeAutoScreen = true;
          vmRunNestedVirt = true;
        };

      };
    };

  nixosModule =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      config = {
        # Bootstrap cache signing key on NixOS guests if missing.
        # The secret key remains local at /etc/nix and is not stored in the Nix store.
        services.nxmaticCachixWatchStore.sopsEncryptedTokenFile = ../../.secrets;
        nix.settings.secret-key-files = [ "/etc/nix/bioskop-cache.key" ];
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
      };
    };
in
{
  inherit hostProfile profileModule;
  darwinExtraModules = [ darwinModule ];
  nixosExtraModules = [ nixosModule ];
}
