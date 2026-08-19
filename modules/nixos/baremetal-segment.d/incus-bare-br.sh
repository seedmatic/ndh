#!/usr/bin/env bash
# Reconcile a managed Incus network from a declarative manifest — the "belt" for
# the create-only nixpkgs preseed, which is ignored on an already-initialised
# incus and never reconciles later field changes.  See
# modules/nixos/baremetal-segment.nix (the preseed is the other belt, for a
# fresh init).
#
# Idempotent: create-if-absent, then deep-merge the manifest into the live
# network's config and apply it in ONE structured `incus network edit`.  Run as a
# systemd oneshot — journald captures the xtrace, so there is no logger here (that
# is for activation/standalone scripts, not services).
#
# Build-time tokens (pkgs.replaceVars): incus, yq, network, manifest — manifest is
# a JSON file {key: value} of the network settings (the single-source bareBrConfig,
# via builtins.toJSON — no nix YAML codec needed).  Written WITHOUT at-sigils:
# replaceVars substitutes any at-sigil placeholder in this comment too.
set -euxo pipefail

@incus@ network create @network@ 2>/dev/null || true

# Apply the whole desired config in ONE structured operation, NOT a per-key
# `incus network set` loop.  The loop was fragile — `IFS= read` + word-splitting of
# values containing spaces/quotes/'=' (e.g. raw.dnsmasq's host-record) — and used
# the now-deprecated `<key> <value>` set syntax (Incus warns).  Instead: read the
# live network YAML, deep-merge our manifest into `.config` (our keys win, other
# keys preserved), and pipe it straight back to `incus network edit` (yq-go parses
# the JSON manifest as YAML — JSON ⊂ YAML — and emits YAML, which edit reads on stdin).
#
# Retried: incus uses optimistic-concurrency ETags, so a concurrent bump (a dnsmasq
# lease update, an overlapping activation) can fail the write with "ETag doesn't
# match".  The old loop had N such windows and aborted mid-way; this is one atomic
# edit, retried a few times.
for attempt in 1 2 3 4 5; do
  if @incus@ network show @network@ \
    | @yq@ '.config = (.config // {}) * load("@manifest@")' \
    | @incus@ network edit @network@; then
    exit 0
  fi
  echo "[incus-bare-br] network edit attempt ${attempt} failed (ETag conflict?), retrying" >&2
  sleep 1
done
echo "[incus-bare-br] network edit failed after 5 attempts" >&2
exit 1
