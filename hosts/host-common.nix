{
  hostProfile,
  darwinProfile,
  # Headscale server URL override.  Normally unset: the default is
  # derived from `catalog.headscale.aliasUrl`, which is the DuckDNS
  # endpoint (mammoth-skate.duckdns.org:41841) that works universally
  # (on-LAN via NAT hairpinning, off-LAN via WAN port forward).
  # Override only when a specific host needs to pin a different
  # control-plane (e.g. a test rig pointing at a staging headscale).
  headscaleServerUrl ? null,
  headscaleEnableSSH ? true,
}:
{
  lib,
  ...
}:
let
  homeManagerExplicitlyDisabled =
    hostProfile ? enableHomeManager
    && hostProfile.enableHomeManager != null
    && hostProfile.enableHomeManager == false;
in
{
  imports = [
    ../profile.nix
    # Fleet-wide headscale-client wiring (networking.tailnet.*,
    # tailnet.headscale.auth.<kind>.enable).  Factored out so the
    # minimal bringup image (modules/nixos/bringup-minimal-system.nix)
    # can import the exact same wiring without pulling the rest of
    # host-common.
    ../modules/.common.d/tailnet-client-wiring.nix
    # Tailscale Services rendering.  Deliberately NOT imported by the bringup image:
    # that toplevel is an EROFS layer the whole fleet shares, so it has no per-host
    # identity to advertise a service under — the same reason it no longer joins the
    # tailnet at all (see docs/bringup-image-unification.adoc, R3).
    ../modules/.common.d/tailnet-services.nix
  ];

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

    # Host-level overrides on top of the shared headscale-client
    # wiring.  `serverUrl` only lands when the caller explicitly
    # passed one; otherwise the shared module's default
    # (catalog.headscale.aliasUrl) wins.
    networking.tailnet = {
      enableSSH = headscaleEnableSSH;
    }
    // (lib.optionalAttrs (headscaleServerUrl != null) {
      serverUrl = headscaleServerUrl;
    });
  };
}
