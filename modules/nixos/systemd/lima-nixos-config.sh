#!/usr/bin/env bash
# lima-nixos-config: Link (preferred) or optionally clone the nix-darwin-home repo
# Usage: lima-nixos-config <HOSTNAME>
# Optional env vars:
#   RKE2LAB_NIXOS_CONFIG_PATH  - explicit repo path
#   RKE2LAB_NIXOS_ALLOW_CLONE=1  - permit fallback clone if no working copy found
set -euxo pipefail
NDH_NIX_CLI_ARGS="${NDH_NIX_CLI_ARGS:--L -v -v}"

ndh:nix:run() {
  local -a ndh_nix_cli_args=()
  if [[ -n "${NDH_NIX_CLI_ARGS}" ]]; then
    read -r -a ndh_nix_cli_args <<< "${NDH_NIX_CLI_ARGS}"
  fi
  nix "${ndh_nix_cli_args[@]}" "$@"
}

HOSTNAME="${1:-}"
if [ -z "${HOSTNAME}" ]; then
  : "[lima-nixos-config] ERROR: missing host argument" >&2
  exit 1
fi

if [ -r /etc/nixos/flake.nix ]; then
  : "[lima-nixos-config] /etc/nixos/flake.nix already present; nothing to do"
  exit 0
fi

: "[lima-nixos-config] Preparing configuration for host ${HOSTNAME}"
mkdir -p /var/lib/nixos

: "Determine current user for path heuristics"
USERNAME=$(id -un)

: "Accumulate candidate repo directories"
CANDIDATES=()
add_candidate() {
  local p="$1"
  [ -z "$p" ] && return 0
  for e in "${CANDIDATES[@]:-}"; do [ "$e" = "$p" ] && return 0; done
  CANDIDATES+=("$p")
}

# 1. Explicit override
add_candidate "${RKE2LAB_NIXOS_CONFIG_PATH:-}"
# 2 & 3: Mounted macOS & Linux style homes
add_candidate "/Volumes/git-worktree-store/nxmatic/nix-darwin-home"
add_candidate "/private/var/lib/git/nxmatic/nix-darwin-home"
add_candidate "/var/lib/git/nxmatic/nix-darwin-home"

SRC=""
for cand in "${CANDIDATES[@]:-}"; do
  [ -z "$cand" ] && continue
  if [ -f "$cand/hosts/$HOSTNAME/flake.nix" ]; then
    SRC="$cand"
    break
  fi
done

if [ -n "$SRC" ]; then
  : "[lima-nixos-config] Using existing working copy: $SRC"
  if [ -e /var/lib/nixos/config ] && [ ! -L /var/lib/nixos/config ]; then
    : "[lima-nixos-config] Existing non-symlink /var/lib/nixos/config present; leaving in place" >&2
  else
    ln -sfn "$SRC" /var/lib/nixos/config
  fi
else
  : "[lima-nixos-config] No existing working copy found among candidates:" >&2
  # Still display list (kept echo for visibility of candidates if needed)
  printf '  %s\n' "${CANDIDATES[@]:-}" >&2
  if [ "${RKE2LAB_NIXOS_ALLOW_CLONE:-0}" = "1" ]; then
    : "[lima-nixos-config] RKE2LAB_NIXOS_ALLOW_CLONE=1 set; cloning repository config" >&2
    ndh:nix:run flake clone -f /var/lib/nixos/config github:nxmatic/nix-darwin-home
  else
    : "[lima-nixos-config] ERROR: no working copy found and clone fallback disabled" >&2
    : "[lima-nixos-config] Set RKE2LAB_NIXOS_CONFIG_PATH to a mounted checkout or set RKE2LAB_NIXOS_ALLOW_CLONE=1 to permit clone." >&2
    exit 1
  fi
fi

: "[lima-nixos-config] Linking host-specific flake into /etc/nixos"
mkdir -p /etc/nixos
ln -fs /var/lib/nixos/config/hosts/$HOSTNAME/flake.nix /etc/nixos/flake.nix

: "[lima-nixos-config] Done."
