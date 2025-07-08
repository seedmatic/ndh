{ config, pkgs, lib, ... }:
let cfg = config.containerHost;
in {

  options.containerHost = {
    enable = lib.mkEnableOption "Container Host support";

    hostName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "The name of the container host, defaults to <hostname>.";
    };

    guestName = lib.mkOption {
      type = lib.types.str;
      default = "guest";
      description = "The name of the container guest, defaults to 'container'.";
    };

    domainName = lib.mkOption {
      type = lib.types.str;
      default = "mammoth-skate.ts.net";
      description =
        "The domain to use for the lima host, defaults to 'mammoth-skate.ts.net'.";
    };

    tailscaleInterfaceName = lib.mkOption {
      type = lib.types.str;
      default = "tailscale0";
      description =
        "The name of the Tailscale interface, defaults to 'tailscale0'.";
    };
  };

  config = lib.mkIf cfg.enable {
    system.stateVersion = "25.05";

    networking.hostName = "${cfg.hostName}-${cfg.guestName}";

    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
      options = [ "size=1G" "mode=755" ];
    };

    boot.loader.grub.devices = [ "nodev" ];

    nix.settings = {
      accept-flake-config = true;
      experimental-features = [ "nix-command" "flakes" ];
    };

    services.tailscale.interfaceName = cfg.tailscaleInterfaceName;
  };
}
