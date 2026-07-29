{
  config,
  lib,
  ndh,
  ...
}:
# Provider-agnostic VM identity: the host↔guest topology shared by every
# consumer (openssh, ssh-keys enrichment, container registry, networking).
# It names a ROLE, not a tool — it must evaluate and be consumable without
# knowing which provider (tart, …) materializes the guest. Provider modules
# depend on this; this depends on no provider. (This is the decoupling the
# old lima-named module lacked.)
let
  inherit (lib) mkOption types;
  ndhContext = ndh.context;
  hostProfile = ndhContext.hostProfile;
  catalog = ndhContext.catalog;
  cfg = config.vm;
  profileUser = lib.attrByPath [
    "profile"
    "user"
    "name"
  ] (throw "vm: required option profile.user.name is missing") config;
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
  options.vm = {
    role = mkOption {
      type = types.enum [
        "host"
        "guest"
      ];
      default = "host";
      description = "Whether this system is the VM host (the Mac) or the guest it runs.";
    };
    hostName = mkOption {
      # Inert static default; the dynamic value is applied in config with mkDefault.
      type = types.str;
      default = "vm-host";
      description = "The VM host name. Defaults (via mkDefault) to hostAlias if defined, else profile.host.hostName.";
    };
    guestName = mkOption {
      type = types.str;
      default = "nixos";
      description = "Name of the guest system running on the host.";
    };
    domainName = mkOption {
      type = types.str;
      default = baseTailnetDomain;
      description = "Domain for the VM host; defaults to the tailnet domain.";
    };
  };
  config = {
    # Apply the dynamic default here so other definitions (e.g. from the flake) can override.
    vm.hostName = lib.mkDefault derivedHostName;

    environment.variables = rec {
      NDH_RDP_HOST = hostName;
      NDH_VZ_HOST = hostName;
      NDH_VZ_GUEST = guestName;
      NDH_DOMAIN = domainName;
      NDH_USER = profileUser;
    };
    networking.hostName = lib.mkForce (
      if cfg.role == "guest" then "${hostName}-${guestName}" else hostName
    );
  };
}
