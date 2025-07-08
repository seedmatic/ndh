{ config, pkgs, lib, ... }:
let cfg = config.limaHost;
in {
  options.limaHost = {
    isGuest = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set to true if this is the guest system.";
    };
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "host";
      description = "The name of the lima host, defaults to <hostname>.";
    };
    guestName = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "The name of the lima guest, defaults to 'nixos'.";
    };
    domainName = lib.mkOption {
      type = lib.types.str;
      default = "mammoth-skate.ts.net";
      description =
        "The domain to use for the lima host, defaults to mammoth-skate.ts.net.";
    };
  };
  config = {
    networking.hostName = lib.mkDefault (if cfg.isGuest then
      "${cfg.hostName}-${cfg.guestName}"
    else
      cfg.hostName);
  };
}
