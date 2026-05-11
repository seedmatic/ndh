{
  self,
  lib,
  pkgs,
  options,
  ...
}:
# Fleet-wide cache trust + signing wiring.
#
# This is the behaviour module paired with the data module at
# catalog/cache-trust.nix. It walks every entry in the catalog and
# emits the corresponding nix.settings + /etc/nix artifacts, so adding
# or removing a cache (or rotating a signing key) is a single edit in
# the catalog — no per-consumer hand-picking.
#
# Emissions by catalog shape:
#
#   caches.<name>.substituter       → extra-substituters += [ url ]
#   caches.<name>.publicKey         → extra-trusted-public-keys += [ key ]
#   caches.<name>.publicKeys        → extra-trusted-public-keys += keys
#   caches.cachix.<name>.publicKey  → same as above, PLUS:
#     - /etc/nix/<name>.pub written declaratively from catalog pub
#     - nix.settings.secret-key-files += /etc/nix/<name>.key
#     - activation wrapper composes /etc/nix/<name>.key from the bare
#       SOPS-deployed value at /run/secrets/<name>.key.bare (see
#       modules/.common.d/sops.nix).
let
  cacheTrust = import "${self}/catalog/cache-trust.nix";
  allCaches = cacheTrust.caches;

  # Fleet-owned entries under caches.cachix.<name>. These have their
  # private deployed from catalog/cache-trust.yaml; the others do not.
  cachixCaches = allCaches.cachix or { };
  externalCaches = builtins.removeAttrs allCaches [ "cachix" ];

  # Collect all publicKey / publicKeys across external caches.
  externalPubs = lib.flatten (
    lib.mapAttrsToList (
      _: entry:
      (lib.optional (entry ? publicKey) entry.publicKey)
      ++ (entry.publicKeys or [ ])
    ) externalCaches
  );

  # Cachix entries each contribute one publicKey (they don't have `publicKeys` lists).
  cachixPubs = lib.mapAttrsToList (_: entry: entry.publicKey) cachixCaches;

  # All substituters (external only — cachix entries aren't published).
  externalSubstituters = lib.flatten (
    lib.mapAttrsToList (
      _: entry: lib.optional (entry ? substituter) entry.substituter
    ) externalCaches
  );

  cachixNames = builtins.attrNames cachixCaches;

  # Activation-time wrapper: compose /etc/nix/<name>.key from SOPS-deployed
  # bare bytes + the catalog key name. Runs on both Darwin and NixOS; each
  # platform anchors it differently (system.activationScripts on Darwin,
  # systemd oneshot on NixOS).
  composeScript = pkgs.writeShellScript "cache-trust-compose" ''
    set -euo pipefail
    ${lib.concatMapStringsSep "\n" (name: ''
      bare=/run/secrets/${name}.key.bare
      final=/etc/nix/${name}.key
      if [ -r "$bare" ]; then
        tmp="$(mktemp)"
        printf '%s:%s\n' ${lib.escapeShellArg name} "$(cat "$bare")" > "$tmp"
        install -m 0600 -o root "$tmp" "$final"
        rm -f "$tmp"
      else
        echo "[cache-trust] bare secret missing: $bare (will retry after sops-install-secrets)" >&2
      fi
    '') cachixNames}
  '';
in
{
  config = {
    nix.settings = {
      # Every catalog pub is trusted; walker accumulates external + cachix.
      extra-trusted-public-keys = externalPubs ++ cachixPubs;
      # Append to nix's default substituter list.
      extra-substituters = externalSubstituters;
      # Secret key files for fleet-owned signing (one per cachix entry).
      secret-key-files = map (name: "/etc/nix/${name}.key") cachixNames;
    };

    # Public counterparts next to the deployed private, for audit + ssh-ng clients.
    environment.etc = lib.mapAttrs' (
      name: entry:
      lib.nameValuePair "nix/${name}.pub" { text = entry.publicKey + "\n"; }
    ) cachixCaches;

  }
  // lib.optionalAttrs (!(options ? systemd.services)) {
    # Darwin branch (no systemd option surface). nix-darwin's sops-
    # install-secrets runs as part of postActivation at lib.mkOrder 1000;
    # anchoring at mkOrder 1200 lands this composer afterwards, before
    # anything that might restart nix-daemon.
    system.activationScripts.cacheTrustCompose = lib.mkOrder 1200 "${composeScript}";
  }
  // lib.optionalAttrs (options ? systemd.services) {
    # NixOS branch. systemd unit After sops-install-secrets, Before
    # nix-daemon. lib.optionalAttrs gates by feature presence (the
    # `systemd` option surface) rather than by platform name — cleaner
    # than branching on pkgs.stdenv.
    systemd.services.cache-trust-compose = {
      description = "Compose fleet cache signing keys from SOPS-deployed bare values (@codebase)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
      before = [ "nix-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "root";
        ExecStart = composeScript;
      };
    };
  };
}
