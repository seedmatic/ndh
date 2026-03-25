#!/usr/bin/env -S bash -euo pipefail
# Shared post-activation wrapper (@codebase)
# Platform layers (darwin/nixos) must provide activation-logger.sh.

source @activationLogger@

main() {
  HM_ACTIVATE="@hmActivationPackage@/activate"
  HM_BASH="@bashBin@"
  if [ -n "$HM_ACTIVATE" ] && [ -x "$HM_ACTIVATE" ]; then
    local activation_session_id
    local activation_log_file activation_log_session_file
    activation_session_id="hm-$(date +%s)-$$"
    activation_log_file="@userHome@/.local/state/nix/activation.log"
    activation_log_session_file="${activation_log_file}.session"

    # Self-heal stale root-owned activation logs from previous root-scoped runs.
    if [ -e "$activation_log_file" ]; then
      chown @userName@ "$activation_log_file" 2>/dev/null || true
    fi
    if [ -e "$activation_log_session_file" ]; then
      chown @userName@ "$activation_log_session_file" 2>/dev/null || true
    fi

    sudo -u @userName@ \
      HOME="@userHome@" \
      XDG_RUNTIME_DIR="@userHome@/.xdg" \
      ACTIVATION_LOG_FILE="$activation_log_file" \
      ACTIVATION_LOG_SESSION_FILE="$activation_log_session_file" \
      ACTIVATION_LOG_SESSION_ID="$activation_session_id" \
      "$HM_BASH" "$HM_ACTIVATE"
  else
    echo "home-manager activation package missing for @userName@, skipping" >&2
  fi

  # nix-darwin is the canonical activation path in this repository.
  # If a stale standalone Home Manager profile symlink exists, clean it up to
  # avoid split-brain behavior (runtime state diverges from nix-darwin output).
  local hmProfilesDir hmStandaloneLink hmStandaloneTarget hmStandaloneAbs
  hmProfilesDir="@userHome@/.local/state/nix/profiles"
  hmStandaloneLink="$hmProfilesDir/home-manager"

  if [ -L "$hmStandaloneLink" ]; then
    hmStandaloneTarget="$(readlink "$hmStandaloneLink")"

    if [[ "$hmStandaloneTarget" = /* ]]; then
      hmStandaloneAbs="$hmStandaloneTarget"
    else
      hmStandaloneAbs="$hmProfilesDir/$hmStandaloneTarget"
    fi

    if [ ! -e "$hmStandaloneAbs" ]; then
      echo "Removing stale standalone Home Manager profile link: $hmStandaloneLink -> $hmStandaloneTarget" >&2
      rm -f "$hmStandaloneLink"
    fi
  fi
}

activation_run "@activationTag@" main "$@"
