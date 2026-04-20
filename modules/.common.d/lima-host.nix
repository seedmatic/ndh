{
  config,
  lib,
  ndh,
  ...
}:
let
  inherit (lib) mkOption;
  ndhContext = ndh.context;
  hostProfile = ndhContext.hostProfile;
  catalog = ndhContext.catalog;
  # Access limaHost after options layer
  cfg = config.limaHost;
  profileUser = lib.attrByPath [
    "profile"
    "user"
    "name"
  ] (throw "lima-host: required option profile.user.name is missing") config;
  derivedHostName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;
  hostName = cfg.hostName;
  guestName = cfg.guestName;
  baseTailnetDomain =
    if catalog.netplan ? tailnet && (catalog.netplan.tailnet ? domain) then
      lib.removePrefix "." catalog.netplan.tailnet.domain
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
      NDH_RDP_HOST = hostName;
      NDH_VZ_HOST = hostName;
      NDH_VZ_GUEST = guestName;
      NDH_DOMAIN = domainName;
      NDH_USER = profileUser;
    };
    networking.hostName = lib.mkForce (if cfg.isGuest then "${hostName}-${guestName}" else hostName);
  };
}
