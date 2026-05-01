let
  hostProfile = {
    hostName = "nikopol";
    form = "vm";
    vmProvider = "lima";
    nixosBootLoader = "systemd-boot";
    nixosBootstrapDebug = false;
    nixosBringupRootFs = "btrfs";
    # Keep explicit host defaults for image-build VM resources.
    # These match canonical defaults from modules/nixos/outputs.nix.
    nixosDiskImageVmMemSizeMiB = 6144;
    nixosDiskImageVmCpuCores = 6;
    # Enlarge per-disk ZFS bringup pool members to evaluate occupancy with full runtime image install.
    nixosZfsBootstrapPoolDiskSizeMiB = 8192;
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

        # VM config materialization is handled by Home Manager activation only
        # for user-scoped assets/gcroots on VZ hosts.
        lima.configGenerator = {
          enableActivationHook = false;
          installMaterializerPackage = false;
        };

        tart.configGenerator = {
          forceEnable = false;
          enableActivationHook = false;
          installMaterializerPackage = false;
        };
      };
    };

  nixosModule =
    {
      config,
      lib,
      ndh,
      ...
    }:
    let
      ndhContext = ndh.context;
      hostProfile = ndhContext.hostProfile;
      bringupMode = ndhContext.generationMode == "bringup";
    in
    {
      config = {
        profile.user.home = lib.mkForce "/home/${config.profile.user.name}";
      }
      // (lib.optionalAttrs (!bringupMode) {
        networking.vlan = {
          enable = true;
          id = 2;
          addressPrefix = "192.168.2";
          parentInterface = "vmlan0";
          addressSourceInterface = "lan-br";
        };
      });
    };
in
{
  inherit hostProfile profileModule;
  darwinExtraModules = [ darwinModule ];
  nixosExtraModules = [ nixosModule ];
}
