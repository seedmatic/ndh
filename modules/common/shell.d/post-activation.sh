#!/usr/bin/env -S bash -euo pipefail
# Shared post-activation wrapper (@codebase)
# Platform layers (darwin/nixos) must provide logger.sh.

source @logger@

main() {
  emit_notice() {
    local msg="$1"
    echo "$msg" >&2
    if { true >&3; } 2>/dev/null; then
      echo "$msg" >&3
    fi
  }

  local platform_log_show_label platform_log_show_cmd
  local platform_log_stream_label platform_log_stream_cmd
  platform_log_show_label="@postActivationLogShowLabel@"
  platform_log_show_cmd="@postActivationLogShowCmd@"
  platform_log_stream_label="@postActivationLogStreamLabel@"
  platform_log_stream_cmd="@postActivationLogStreamCmd@"

  emit_platform_log_hints() {
    if [ -n "$platform_log_show_cmd" ]; then
      emit_notice "[post-activation] ${platform_log_show_label}: ${platform_log_show_cmd}"
    fi
    if [ -n "$platform_log_stream_cmd" ]; then
      emit_notice "[post-activation] ${platform_log_stream_label}: ${platform_log_stream_cmd}"
    fi
  }

  HM_ACTIVATE="@hmActivationPackage@/activate"
  if [ -n "$HM_ACTIVATE" ] && [ -x "$HM_ACTIVATE" ]; then
    local activation_session_id
    local activation_log_file activation_log_session_file
    activation_session_id="hm-$(date +%s)-$$"
    activation_log_file="@userHome@/.local/state/nix/activation.log"
    activation_log_session_file="${activation_log_file}.session"

    # Keep only the latest activation log content for easier review.
    install -d -m 700 "$(dirname "$activation_log_file")"
    : > "$activation_log_file"
    printf '%s\n' "$activation_session_id" > "$activation_log_session_file"

    emit_notice "[post-activation] Home Manager activation logger sink: ${LOGGER_CMD:-<stderr-only>}"
    emit_notice "[post-activation] Home Manager activation log file: $activation_log_file"
    emit_notice "[post-activation] Home Manager activation session file: $activation_log_session_file"
    emit_notice "[post-activation] Home Manager activation session id: $activation_session_id"
    emit_platform_log_hints

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
      "$HM_ACTIVATE"

    emit_notice "[post-activation] Home Manager activation finished."
    if [ -n "$platform_log_show_cmd" ]; then
      emit_notice "[post-activation] To inspect activation logs now, run: ${platform_log_show_cmd}"
    fi
    if [ -n "$platform_log_stream_cmd" ]; then
      emit_notice "[post-activation] To follow activation logs live, run: ${platform_log_stream_cmd}"
    fi
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

ndh::logger:command:run "@activationTag@" main "$@"
