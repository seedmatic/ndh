# Shared headscale-client wiring.  Platform-agnostic: reads
# `ndh.headscaleClient.kind` (set by the platform module) and emits
# the corresponding `networking.headscale.*` + `tailnet.headscale.auth.<kind>.enable`.
#
# Caller responsibilities — exactly one per (platform × host):
#   - modules/darwin/headscale-client-kind.nix: sets kind = "darwin"
#   - modules/nixos/headscale-client-kind.nix:  sets kind = "nixos"
#   - A host that needs a non-default kind (e.g. a NixOS host acting
#     as an incus/rke2 node) overrides `ndh.headscaleClient.kind` in
#     its own host profile.
#
# Importing this file IS the opt-in to joining the fleet tailnet:
# `networking.headscale.enable` is set unconditionally.  Configs
# that must not join the tailnet simply don't import this file.
{
  config,
  lib,
  ndh ? null,
  ...
}:
let
  cfg = config.ndh.headscaleClient;
  headscaleCatalog = lib.attrByPath [ "context" "catalog" "headscale" ] null ndh;

  # Deterministic mapping from the kind axis to the (role, kind) tag
  # pair.  `darwin` is the only kind that registers as console-
  # attached by default (a human sits at it); every other kind is
  # headless (server / VM / container / cluster member).  A future
  # darwin-that's-actually-headless (mac mini in a closet) overrides
  # `ndh.headscaleClient.kind` or sets its role tag directly.
  tagsForKind =
    kind:
    let
      roleTag =
        if kind == "darwin" then headscaleCatalog.tags.role.console else headscaleCatalog.tags.role.headless;
      kindTag = lib.attrByPath [
        "tags"
        "kind"
        kind
      ] null headscaleCatalog;
    in
    if headscaleCatalog == null || kindTag == null then
      [ ]
    else
      [
        roleTag
        kindTag
      ];

  effectiveServerUrl =
    if headscaleCatalog != null then headscaleCatalog.aliasUrl else "";
in
{
  options.ndh.headscaleClient = {
    kind = lib.mkOption {
      type = lib.types.enum [
        "darwin"
        "nixos"
        "incus"
        "rke2"
      ];
      description = ''
        The headscale-auth kind this host registers as.  Drives two
        things: the `tailnet.headscale.auth.<kind>` sops slot that
        materialises the preauth key, and the `(role, kind)` tag pair
        the node asserts at registration — `tag:console,tag:darwin`
        for darwin, `tag:headless,tag:<other>` for every other kind.

        Set by platform modules (modules/darwin/… or modules/nixos/…),
        not by bare hosts — unless a host genuinely needs a kind other
        than the platform default (e.g. a NixOS host serving as an
        rke2 node).
      '';
    };
  };

  config = {
    networking.headscale = {
      enable = true;
      serverUrl = lib.mkDefault effectiveServerUrl;
      tags = lib.mkDefault (tagsForKind cfg.kind);
    };

    # Enable only the matching kind slot; all others stay sealed.
    tailnet.headscale.auth.${cfg.kind}.enable = true;

    # Trust the `mammoth-skate` CA system-wide so every client on
    # this host (tailscale, curl, browsers) accepts the self-signed
    # leaf cert serving `headscale.mammoth-skate.local`.  Same
    # option name on Darwin + NixOS (both flavours of nix-pki
    # expose `security.pki.certificates`).  `ca_crt` is a plaintext
    # field inside the sops-encrypted keys.yaml — cert bytes are
    # public-trust-anchor material — so we can read it at eval time
    # without sops decryption.
    security.pki.certificates = lib.optional (
      config.ndh.keysYaml.authorities ? mammoth-skate
      && config.ndh.keysYaml.authorities.mammoth-skate ? ca_crt
    ) config.ndh.keysYaml.authorities.mammoth-skate.ca_crt;
  };
}
