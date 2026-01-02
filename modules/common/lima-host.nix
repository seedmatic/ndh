{
  config,
  lib,
  hostProfile ? null,
  ...
}:
let
  inherit (lib) mkOption;
  # Access limaHost after options layer
  cfg = config.limaHost;
  # Resolve profile host data without creating a recursive dependency on limaHost itself.
  # Prefer the injected specialArg hostProfile if provided (flake does this already for NixOS),
  # otherwise fall back to config.profile.host.
  resolvedHostProfile = if hostProfile != null then hostProfile else config.profile.host;
  derivedHostName =
    if
      (
        resolvedHostProfile ? hostAlias
        && resolvedHostProfile.hostAlias != null
        && resolvedHostProfile.hostAlias != ""
      )
    then
      resolvedHostProfile.hostAlias
    else
      resolvedHostProfile.hostName;
  hostName = cfg.hostName;
  guestName = cfg.guestName;
  domainName = cfg.domainName;
in
{
  options.limaHost = {
    isGuest = mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set to true if this is the guest system.";
    };
    hostName = mkOption {
      type = lib.types.str;
      # Keep an inert static default; dynamic behavior applied in config with mkDefault (@codebase)
      default = "lima-host";
      description = "The lima host name. Defaults (via mkDefault) to hostAlias if defined, else profile.host.hostName.";
    };
    guestName = mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "The name of the lima guest, defaults to 'nixos'.";
    };
    domainName = mkOption {
      type = lib.types.str;
      default = "mammoth-skate.ts.net";
      description = "The domain for the lima host, defaults to mammoth-skate.ts.net.";
    };
  };
  config = {
    # Apply dynamic default safely here so other definitions (e.g. from flake) can override.
    limaHost.hostName = lib.mkDefault derivedHostName;

    environment.variables = rec {
      LIMA_HOSTNAME = hostName;
      LIMA_GUESTNAME = guestName;
      LIMA_DN = domainName;
    };
    networking.hostName = lib.mkForce (if cfg.isGuest then "${hostName}-${guestName}" else hostName);
  };
}
