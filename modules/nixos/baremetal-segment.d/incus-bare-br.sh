#!/usr/bin/env bash
# Reconcile a managed Incus network from a declarative manifest — the "belt" for
# the create-only nixpkgs preseed, which is ignored on an already-initialised
# incus and never reconciles later field changes.  See
# modules/nixos/baremetal-segment.nix (the preseed is the other belt, for a
# fresh init).
#
# Idempotent: create-if-absent, then `set` each key so an existing network
# converges.  Run as a systemd oneshot — journald captures the xtrace, so there
# is no logger here (that is for activation/standalone scripts, not services).
#
# Build-time tokens (pkgs.replaceVars): incus, yq, network, manifest — manifest
# is a JSON file {key: value} of the network settings (the single-source
# bareBrConfig, via builtins.toJSON — no nix YAML codec needed), parsed with
# yq-go in JSON-input mode.  Written WITHOUT at-sigils: replaceVars substitutes
# any at-sigil placeholder in this comment too.
set -euxo pipefail

@incus@ network create @network@ 2>/dev/null || true

# Apply each setting from the manifest.  yq-go (JSON input) is robust vs values
# containing spaces/quotes/'=' (e.g. raw.dnsmasq), and bracket-indexing handles
# dotted keys like `ipv4.address` (a dot is a path separator otherwise).
@yq@ -p=json 'keys | .[]' @manifest@ | while IFS= read -r key; do
  [ -n "$key" ] || continue
  value="$(@yq@ -p=json ".[\"$key\"]" @manifest@)"
  @incus@ network set @network@ "$key" "$value"
done
