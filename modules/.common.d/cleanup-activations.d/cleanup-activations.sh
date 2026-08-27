#!/usr/bin/env bash
# @codebase
set -euo pipefail

# Cleanup helper for nix-darwin systems.
# Keeps only current generations across:
#  - nix-darwin system profile
#  - Home Manager profile (if installed)
#  - user nix profile
# Then runs garbage collection.

log() {
  printf '[cleanup-activations] %s\n' "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_or_echo() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY_RUN: %q' "$1"
    shift
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

main() {
  local user_profile
  user_profile="/nix/var/nix/profiles/per-user/${USER}/profile"

  if [[ "${EUID}" -ne 0 ]]; then
    log "Running as user '${USER}'. You will be prompted for sudo where needed."
  fi

  log "1/4 Pruning nix-darwin system generations (keep current only)"
  run_or_echo sudo nix-env -p /nix/var/nix/profiles/system --delete-generations old

  if have_cmd home-manager; then
    log "2/4 Pruning Home Manager generations (keep current only)"
    run_or_echo home-manager expire-generations "0 days"
  else
    log "2/4 Home Manager not found in PATH, skipping"
  fi

  if have_cmd nix; then
    log "3/4 Pruning user profile history (${user_profile})"
    run_or_echo nix profile wipe-history --profile "${user_profile}"
  else
    log "3/4 nix CLI not found in PATH; cannot wipe user profile history"
  fi

  log "4/4 Running garbage collection"
  run_or_echo sudo nix-collect-garbage -d

  log "Done. Suggested checks:"
  log "  darwin-rebuild --list-generations"
  log "  home-manager generations"
  log "  nix profile history --profile ${user_profile}"
}

main "$@"
