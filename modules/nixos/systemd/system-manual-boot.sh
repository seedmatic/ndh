#!/usr/bin/env bash
# system-manual-boot: build & set next boot generation (no live activation)
# Placeholders: @hostName@ @systemAttr@ @flakeRef@
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi
FLAKE="${1:-@flakeRef@}"
: "→ building (boot) system closure for host @hostName@ via flake $FLAKE"
nix build "$FLAKE"#@systemAttr@ --print-build-logs
newPath=$(nix path-info "$FLAKE"#@systemAttr@)
: "→ setting boot generation: $newPath"
nix-env -p /nix/var/nix/profiles/system --set "$newPath"
: "→ boot generation set. Reboot to apply."

