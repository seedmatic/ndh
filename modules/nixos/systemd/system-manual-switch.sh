#!/usr/bin/env bash
# system-manual-switch: build & activate a system generation without transient systemd-run
# Placeholders substituted by Nix: @hostName@ @systemAttr@ @flakeRef@
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi
FLAKE="${1:-@flakeRef@}"
: "→ building system closure for host @hostName@ via flake $FLAKE"
tmpBuildDir=$(mktemp -d)
cleanup() { rm -rf "$tmpBuildDir" || true; }; trap cleanup EXIT INT TERM
nix build "$FLAKE"#@systemAttr@ -o "$tmpBuildDir/toplevel" --print-build-logs
newPath=$(readlink -f "$tmpBuildDir/toplevel")
: "→ setting /nix/var/nix/profiles/system -> $newPath"
nix-env -p /nix/var/nix/profiles/system --set "$newPath"
: "→ running switch-to-configuration (switch)"
"$newPath"/bin/switch-to-configuration switch
: "→ done. Current system: $(readlink /run/current-system)"

