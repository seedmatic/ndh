{ config, pkgs, lib, ... }:
let
  inherit (lib) mkOption;
  cfg = config.limaHost;
  hostName = cfg.hostName;
  guestName = cfg.guestName;
  domainName = cfg.domainName;
in {
  options.limaHost = {
    isGuest = mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set to true if this is the guest system.";
    };
    hostName = mkOption {
      type = lib.types.str;
      default = "host";
      description = "The name of the lima host, defaults to <hostname>.";
    };
    guestName = mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "The name of the lima guest, defaults to 'nixos'.";
    };
    domainName = mkOption {
      type = lib.types.str;
      default = "mammoth-skate.ts.net";
      description =
        "The domain to use for the lima host, defaults to mammoth-skate.ts.net.";
    };
  };
  config = {
    environment.variables = rec {
      LIMA_HOST_NAME = hostName;
      LIMA_GUEST_NAME = guestName;
      LIMA_DOMAIN_NAME = domainName;
    };
    networking.hostName = lib.mkForce ( if cfg.isGuest then "${hostName}-${guestName}" else hostName );
  };
}
