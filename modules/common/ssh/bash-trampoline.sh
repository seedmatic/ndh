#!/usr/bin/env bash
# @codebase
# Shared trampoline for ssh helper scripts.
# Goals:
#  1) Load baseline Nix profile environment when available.
#  2) Re-exec under a Nix-managed bash when current bash is non-Nix.

nxmatic_load_default_nix_profiles() {
  local candidates=(
    "/etc/profile"
    "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
    "$HOME/.nix-profile/etc/profile.d/nix.sh"
    "/etc/profiles/per-user/${USER:-}/etc/profile.d/hm-session-vars.sh"
  )

  local f
  for f in "${candidates[@]}"; do
    [[ -r "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f" >/dev/null 2>&1 || true
  done
}

nxmatic_is_nix_bash() {
  local bash_path="$1"
  case "$bash_path" in
    /nix/*|/run/current-system/sw/bin/bash|/etc/profiles/per-user/*/bin/bash)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

nxmatic_ensure_nix_bash() {
  [[ "${NXMATIC_BASH_TRAMPOLINED:-0}" == "1" ]] && return 0

  local current_bash="${BASH:-$(command -v bash 2>/dev/null || true)}"
  if nxmatic_is_nix_bash "$current_bash"; then
    return 0
  fi

  nxmatic_load_default_nix_profiles

  local candidates=(
    "${NIX_BASH_BIN:-}"
    "/run/current-system/sw/bin/bash"
    "/nix/var/nix/profiles/default/bin/bash"
    "/etc/profiles/per-user/${USER:-}/bin/bash"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if [[ "$candidate" != "$current_bash" ]]; then
      export NXMATIC_BASH_TRAMPOLINED=1
      exec "$candidate" "$0" "$@"
    fi
  done

  return 0
}
