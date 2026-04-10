{
  config,
  lib,
  hostProfile ? null,
  catalog ? { },
  ...
}:
let
  networkCatalog = catalog.networks or { };
  inherit (lib) mkOption;
  # Access limaHost after options layer
  cfg = config.limaHost;
  # Resolve profile host data without creating a recursive dependency on limaHost itself.
  # Prefer the injected specialArg hostProfile if provided (flake does this already for NixOS),
  # otherwise fall back to config.profile.host.
  resolvedHostProfile = if hostProfile != null then hostProfile else config.profile.host;
  profileUser = lib.attrByPath [
    "profile"
    "user"
    "name"
  ] (throw "lima-host: required option profile.user.name is missing") config;
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
  baseTailnetDomain =
    if networkCatalog ? tailnet && (networkCatalog.tailnet ? domain) then
      lib.removePrefix "." networkCatalog.tailnet.domain
    else
      "tailnet.local";
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
      default = baseTailnetDomain;
      description = "The domain for the lima host, defaults to the tailnet domain.";
    };
  };
  config = {
    # Apply dynamic default safely here so other definitions (e.g. from flake) can override.
    limaHost.hostName = lib.mkDefault derivedHostName;

    environment.variables = rec {
      NDH_ACCESS_HOST = hostName;
      NDH_GUEST_NAME = guestName;
      NDH_DOMAIN = domainName;
      NDH_USERNAME = profileUser;
    };
    networking.hostName = lib.mkForce (if cfg.isGuest then "${hostName}-${guestName}" else hostName);
  };
}
