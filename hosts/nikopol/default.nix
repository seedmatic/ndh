let
  hostProfile = {
    hostName = "nikopol";
    tailnet = { };
    nixosImageMode = "bootstrap";
    nixosBootLoader = "systemd-boot";
  };

  darwinProfile = {
    knownNetworkServices = [
      "Wi-Fi"
      "Thunderbolt Ethernet"
    ];
    wallpaperImage = ./assets.d/Scavengers-Reign.jpg;
  };

  profileModule =
    {
      lib,
      config,
      ...
    }:
    {
      imports = [
        (import ../host-common.nix {
          inherit hostProfile darwinProfile;
          headscaleServerUrl = "http://192.168.1.193:8080";
          forceRemoteBuilds = true;
          preferredBuilderHosts = [ "bioskop" ];
        })
      ];
      config = {

        # Explicitly select committed profile for full Home Manager environment
        # on the Darwin VM host.
        profile.name = lib.mkForce "committed";

        # Keep experiment/bootstrap mode until boot/login validation is complete.
        # This avoids stage-2 panic when /etc/sops/age/keys.txt is not yet provisioned.
        ndh.sopsAgeKeyBootstrap.phase = "bootstrap";
        ndh.sopsAgeKeyBootstrap.nixosHostKeyImport.candidates = [
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
        # Keep Darwin user home aligned with vm-mounted persistent volume.
        profile.user.home = lib.mkForce (builtins.toPath "/Volumes/user-home");

        # Keep /net autofs explicit for Lima disk-image path prerequisites.
        services.nfsDarwin = {
          enable = true;
          autofs.enable = true;
          autofs.mountPoint = "/net";
          autofs.installMaterializerPackage = true;
        };

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
      bootstrapMode = (hostProfile.nixosImageMode or "full") == "bootstrap";
    in
    {
      config = {
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
{
  inherit hostProfile profileModule;
  darwinExtraModules = [ darwinModule ];
  nixosExtraModules = [ nixosModule ];
}
