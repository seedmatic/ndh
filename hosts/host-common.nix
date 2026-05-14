{
  hostProfile,
  darwinProfile,
  # Headscale server URL override.  Normally unset: the default is
  # derived from `catalog.headscale.aliasUrl`, which is the
  # fleet-scoped mDNS alias (`headscale.mammoth-skate.local`) that
  # follows the host currently holding `role = "primary"`.  Override
  # only when a specific host needs to pin a different control-plane
  # (e.g. a test rig pointing at a staging headscale).
  headscaleServerUrl ? null,
  headscaleEnableSSH ? true,
}:
{
  lib,
  options,
  ndh ? null,
  ...
}:
let
  hasHeadscaleOption = options ? networking && options.networking ? headscale;
  # Tag vocabulary is shipped in the catalog so every call site names
  # the same strings.  Platform axis is detected from the NixOS-only
  # `systemd` option — Darwin hosts advertise `tag:operator,tag:darwin`,
  # NixOS guests `tag:service,tag:nixos` (matching
  # catalog/headscale/acl.hujson).  Hosts that need a non-default mix
  # (e.g. a darwin admin laptop acting as `tag:operator,tag:service`)
  # set `networking.headscale.tags` directly — it's still `mkDefault`
  # so explicit values win.
  isNixosPlatform = options ? systemd;
  headscaleCatalog = lib.attrByPath [ "context" "catalog" "headscale" ] null ndh;
  headscaleTags =
    if headscaleCatalog != null then
      let
        role =
          if isNixosPlatform then headscaleCatalog.tags.role.service else headscaleCatalog.tags.role.operator;
        kind =
          if isNixosPlatform then headscaleCatalog.tags.kind.nixos else headscaleCatalog.tags.kind.darwin;
      in
      [
        role
        kind
      ]
    else
      [ ];
  effectiveServerUrl =
    if headscaleServerUrl != null then
      headscaleServerUrl
    else if headscaleCatalog != null then
      headscaleCatalog.aliasUrl
    else
      "";
  homeManagerExplicitlyDisabled =
    hostProfile ? enableHomeManager
    && hostProfile.enableHomeManager != null
    && hostProfile.enableHomeManager == false;
in
{
  imports = [ ../profile.nix ];

  config = {
    assertions = [
      {
        assertion = !homeManagerExplicitlyDisabled;
        message = ''
          hostProfile.enableHomeManager must not be set to false in host-common based hosts.
          Keep Home Manager enabled by default and rely on platform/bootstrap gating
          (modules/.common.d/default.nix) for NixOS bootstrap-specific behavior.
        '';
      }
    ];

    profile = {
      host = {
        hostName = lib.mkDefault hostProfile.hostName;
      }
      // (lib.optionalAttrs (hostProfile ? hostAlias) {
        hostAlias = lib.mkDefault hostProfile.hostAlias;
      })
      // (lib.optionalAttrs (hostProfile ? form) {
        form = hostProfile.form;
      });

      darwin = darwinProfile;
    };
  }
  // (lib.optionalAttrs hasHeadscaleOption {
    networking.headscale = {
      enable = true;
      serverUrl = effectiveServerUrl;
      enableSSH = headscaleEnableSSH;
      tags = lib.mkDefault headscaleTags;
    };
    # Materialise the node-registration auth key from the shared
    # tailnet schema ([modules/.common.d/tailnet.nix]) so
    # `hs-connect` can register this host non-interactively.  Only
    # kicks in on hosts that have the `tailnet` option tree (every
    # host importing modules/.common.d, today: all of them).
    tailnet.headscale.auth.enable = true;
  });
}
