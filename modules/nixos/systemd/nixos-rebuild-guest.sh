#!/usr/bin/env bash
# nixos-rebuild-guest: wrapper avoiding systemd-run transient units in guest
# Placeholders: @hostName@ @systemAttr@ @flakeRef@
set -euo pipefail
ACTION="${1:-switch}"
FLAKE="${2:-@flakeRef@}"
case "$ACTION" in
  switch)
    system-manual-switch "$FLAKE" ;;
  boot)
    system-manual-boot "$FLAKE" ;;
  test)
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    nix build "$FLAKE"#@systemAttr@ -o "$tmp/toplevel" --print-build-logs
    newPath=$(readlink -f "$tmp/toplevel")
    : "→ running switch-to-configuration test"
    "$newPath"/bin/switch-to-configuration test
    : "→ test activation complete" ;;
  build)
    nix build "$FLAKE"#@systemAttr@ --print-build-logs
    echo "Result path: $(nix path-info "$FLAKE"#@systemAttr@)" ;;
  dry-build)
    nix build --dry-run "$FLAKE"#@systemAttr@ ;;
  *)
    echo "Unsupported action: $ACTION" >&2
    echo "Usage: nixos-rebuild-guest [switch|boot|test|build|dry-build] [flake]" >&2
    exit 2 ;;
 esac

