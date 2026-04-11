#!/usr/bin/env bash
# system-manual-boot: build & set next boot generation (no live activation)
# Placeholders: @hostName@ @systemAttr@ @flakeRef@
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi
NDH_NIX_CLI_ARGS="${NDH_NIX_CLI_ARGS:--L -v -v}"

ndh:nix:run() {
  local -a ndh_nix_cli_args=()
  if [[ -n "${NDH_NIX_CLI_ARGS}" ]]; then
    read -r -a ndh_nix_cli_args <<< "${NDH_NIX_CLI_ARGS}"
  fi
  nix "${ndh_nix_cli_args[@]}" "$@"
}

FLAKE="${1:-@flakeRef@}"
: "→ building (boot) system closure for host @hostName@ via flake $FLAKE"
ndh:nix:run build "$FLAKE"#@systemAttr@ --print-build-logs
newPath=$(ndh:nix:run path-info "$FLAKE"#@systemAttr@)
: "→ setting boot generation: $newPath"
nix-env -p /nix/var/nix/profiles/system --set "$newPath"
: "→ boot generation set. Reboot to apply."

