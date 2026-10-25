{
  ndh,
  config,
  lib,
  pkgs,
  ...
}:
# Fleet-wide cache trust + signing, platform-agnostic logic.
#
# Paired with the data module at catalog/cache-trust.nix. This walks the
# catalog and emits nix.settings + /etc/nix/<name>.pub + a compose-script
# derivation. The *platform-specific* activation-time wiring (how to run
# the compose script on Darwin vs NixOS) lives in the matching modules
# under modules/darwin/cache-trust.nix and modules/nixos/cache-trust.nix.
#
# Emissions by catalog shape:
#
#   caches.<name>.substituter       → extra-substituters += [ url ]
#   caches.<name>.publicKey         → extra-trusted-public-keys += [ key ]
#   caches.<name>.publicKeys        → extra-trusted-public-keys += keys
#   caches.cachix.<name>.publicKey  → same as above, PLUS:
#     - /etc/nix/<name>.pub written declaratively from catalog pub
#     - nix.settings.secret-key-files += /etc/nix/<name>.key
#     - ndh.cacheTrust.composeScript built here; the per-platform module
#       runs it after sops-install-secrets and before nix-daemon so
#       /etc/nix/<name>.key exists at the moment nix-daemon reads it.
let
  inherit (lib)
    mkOption
    types
    mapAttrsToList
    mapAttrs'
    nameValuePair
    flatten
    optional
    escapeShellArg
    concatMapStringsSep
    ;

  # The catalog's, built once by the flake (catalog/cache-trust.nix fed with nix-flake-commons' upstream caches).
  allCaches = ndh.context.catalog.caches;

  # Fleet-owned entries under caches.cachix.<name>. These have their
  # private deployed from catalog/cache-trust.yaml; the others do not.
  cachixCaches = allCaches.cachix or { };
  externalCaches = builtins.removeAttrs allCaches [ "cachix" ];

  externalPubs = flatten (
    mapAttrsToList (
      _: entry: (optional (entry ? publicKey) entry.publicKey) ++ (entry.publicKeys or [ ])
    ) externalCaches
  );

  cachixPubs = mapAttrsToList (_: entry: entry.publicKey) cachixCaches;

  # The fleet keys this machine SIGNS with, so holds the private of: none once it signs with its own key (its host key
  # serving and its nixSigning recorded, ndh.nixSigning.signs), every one before. Their publics stay trusted
  # everywhere: a path the fleet key signed is still accepted until its trust is cut (roles × keys, after batch 2).
  # A configuration without nix-signing (the bringup and generic images) has no own key, so it keeps the fleet one.
  signsWithOwnKey = (config.ndh.nixSigning or { }).signs or false;
  cachixNames = if signsWithOwnKey then [ ] else builtins.attrNames cachixCaches;
  # The fleet keys it no longer signs with: their private, which an earlier activation wrote, leaves its disk.
  retiredNames = lib.subtractLists cachixNames (builtins.attrNames cachixCaches);

  externalSubstituters = flatten (
    mapAttrsToList (_: entry: optional (entry ? substituter) entry.substituter) externalCaches
  );

  # writeShellApplication: explicit runtimeInputs give the script a
  # deterministic PATH so it never depends on whatever ambient shell
  # launches it (nix-darwin's postActivation, systemd oneshot, etc.).
  # Shellcheck runs at build time — catches typos before activation.
  composeScript = pkgs.writeShellApplication {
    name = "cache-trust-compose";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      # A missing key is a failure, not a warning: nix-daemon would otherwise start with no signing key.
      status=0
      ${concatMapStringsSep "\n" (name: ''
        bare=/run/secrets/${name}.key.bare
        if [ -r "$bare" ]; then
          tmp="$(mktemp)"
          printf '%s:%s\n' ${escapeShellArg name} "$(cat "$bare")" > "$tmp"
          install -m 0600 -o root "$tmp" /etc/nix/${name}.key
          rm -f "$tmp"
        else
          echo "[cache-trust] ERROR: bare secret missing: $bare (sops-install-secrets did not deploy it)" >&2
          status=1
        fi
      '') cachixNames}
      ${concatMapStringsSep "\n" (name: ''
        # Signed with its own key now: the fleet private an earlier activation wrote is removed, and checked gone.
        rm -f /etc/nix/${name}.key
        if [ -e /etc/nix/${name}.key ]; then
          echo "[cache-trust] ERROR: /etc/nix/${name}.key is still there after its removal" >&2
          status=1
        fi
      '') retiredNames}
      exit "$status"
    '';
  };
in
{
  options.ndh.cacheTrust = {
    composeScript = mkOption {
      type = types.package;
      readOnly = true;
      description = ''
        writeShellApplication package exposing `bin/cache-trust-compose`.
        Reads SOPS-deployed bare cache private keys at
        /run/secrets/<name>.key.bare, prepends the `<name>:` wire-format
        prefix, and writes /etc/nix/<name>.key at 0600 root. Platform
        modules invoke this after sops-install-secrets and before
        nix-daemon so the signing key file is in place at daemon start.
      '';
    };

    retiredNames = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      description = "The fleet keypairs this machine no longer signs with: the compose step removes their private from /etc/nix.";
    };

    cachixNames = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      description = ''
        The fleet-owned keypairs (caches.cachix) this machine signs with and holds the private of: every one until it
        signs with its own key (ndh.nixSigning.signs), none after. Their publics are trusted on every machine either
        way. The platform modules and sops read it to deploy and compose those privates only.
      '';
    };
  };

  config = {
    ndh.cacheTrust = {
      inherit composeScript cachixNames retiredNames;
    };

    nix.settings = {
      extra-trusted-public-keys = externalPubs ++ cachixPubs;
      extra-substituters = externalSubstituters;
      secret-key-files = map (name: "/etc/nix/${name}.key") cachixNames;
    };

    environment.etc = mapAttrs' (
      name: entry: nameValuePair "nix/${name}.pub" { text = entry.publicKey + "\n"; }
    ) cachixCaches;
  };
}
