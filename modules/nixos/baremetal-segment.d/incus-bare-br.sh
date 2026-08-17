#!/usr/bin/env bash
# Reconcile a managed Incus network from a declarative key/value set — the
# "belt" for the create-only nixpkgs preseed, which is ignored on an already-
# initialised incus and never reconciles later field changes.  See
# modules/nixos/baremetal-segment.nix (the preseed is the other belt, for a
# fresh init).
#
# Idempotent: create-if-absent, then `set` each key so an existing network
# converges.  Run as a systemd oneshot — journald captures the xtrace, so there
# is no logger here (that is for activation/standalone scripts, not services).
#
# Build-time tokens (pkgs.replaceVars): @incus@ @network@ @keyvals@ (@keyvals@ is
# tab-separated `key<TAB>value` lines from the single-source bareBrConfig).
set -euxo pipefail

@incus@ network create @network@ 2>/dev/null || true

while IFS=$'\t' read -r key value; do
  [ -n "$key" ] || continue
  @incus@ network set @network@ "$key" "$value"
done <<'KEYVALS'
@keyvals@
KEYVALS
