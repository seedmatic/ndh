{
  worktreePath,
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

  cacheTrust = import (worktreePath.of "catalog/cache-trust.nix");
  allCaches = cacheTrust.caches;

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

  externalSubstituters = flatten (
    mapAttrsToList (_: entry: optional (entry ? substituter) entry.substituter) externalCaches
  );

  cachixNames = builtins.attrNames cachixCaches;

  builderSecretsDir = config.ndh.cacheTrust.builderSecretsDir;

  # writeShellApplication: explicit runtimeInputs give the script a
  # deterministic PATH so it never depends on whatever ambient shell
  # launches it (nix-darwin's postActivation, systemd oneshot, etc.).
  # Shellcheck runs at build time — catches typos before activation.
  composeScript = pkgs.writeShellApplication {
    name = "cache-trust-compose";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      ${lib.optionalString (builderSecretsDir != null) ''
        install -d -m 0700 -o root ${escapeShellArg builderSecretsDir}
      ''}
      ${concatMapStringsSep "\n" (name: ''
        bare=/run/secrets/${name}.key.bare
        if [ -r "$bare" ]; then
          tmp="$(mktemp)"
          printf '%s:%s\n' ${escapeShellArg name} "$(cat "$bare")" > "$tmp"
          install -m 0600 -o root "$tmp" /etc/nix/${name}.key
          ${lib.optionalString (builderSecretsDir != null) ''
            install -m 0600 -o root "$tmp" ${escapeShellArg builderSecretsDir}/${name}.key
          ''}
          rm -f "$tmp"
        else
          echo "[cache-trust] bare secret missing: $bare (sops-install-secrets should have deployed it)" >&2
        fi
      '') cachixNames}
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

    cachixNames = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      description = ''
        Names of fleet-owned signing keypairs (keys in caches.cachix).
        Exposed for platform modules that iterate over them when wiring
        the compose invocation.
      '';
    };

    builderSecretsDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Optional host-side directory where the compose script mirrors
        each `<name>.key` in addition to /etc/nix/. Set by platform
        modules that need to expose the signing keys to a nested
        builder VM (e.g. the nix-darwin linux-builder via a 9p share
        at /srv/host/nix-keys). When null, only /etc/nix/<name>.key is
        written. The directory itself is created 0700 root; each key
        file is 0600 root, identical wire format to /etc/nix/<name>.key.
      '';
    };
  };

  config = {
    ndh.cacheTrust = {
      inherit composeScript cachixNames;
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
