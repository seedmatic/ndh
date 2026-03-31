{
  config,
  lib,
  pkgs,
  ...
}:

{
  # System-wide shell configuration for keychain initialization
  # This adds keychain support to all interactive shells for all users

  # Recover automatically when keychain points to a stale SSH agent socket.
  # ssh-add exit code semantics:
  #   0 => keys loaded, 1 => agent reachable but empty, 2 => agent/socket error.
  programs.bash = {
    enable = true;
    interactiveShellInit = ''
      state_keys_dir="${XDG_STATE_HOME:-$HOME/.local/state}/ssh-keys.d"
      if command -v keychain >/dev/null 2>&1 && [[ -f "$state_keys_dir/host" ]]; then
        eval "$(keychain --quiet --eval "$state_keys_dir/host")"

        if command -v ssh-add >/dev/null 2>&1; then
          ssh-add -l >/dev/null 2>&1
          if [[ $? -eq 2 ]]; then
            unset SSH_AUTH_SOCK SSH_AGENT_PID
            eval "$(keychain --quiet --eval "$state_keys_dir/host")"

            ssh-add -l >/dev/null 2>&1
            if [[ $? -eq 2 ]] && command -v launchctl >/dev/null 2>&1; then
              launchd_sock="$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true)"
              if [[ -n "$launchd_sock" ]]; then
                export SSH_AUTH_SOCK="$launchd_sock"
                unset SSH_AGENT_PID
              fi
            fi
          fi

          ssh-add -l >/dev/null 2>&1
          if [[ $? -eq 1 ]]; then
            host_key="$state_keys_dir/host"
            host_cert="$state_keys_dir/host-cert.pub"
            if [[ -f "$host_key" && -f "$host_cert" ]]; then
              key_fp="$(ssh-keygen -lf "$host_key" 2>/dev/null | awk '{print $2}' || true)"
              cert_fp="$(ssh-keygen -Lf "$host_cert" 2>/dev/null | awk '/Public key:/ {print $4; exit}' || true)"
              if [[ -n "$key_fp" && -n "$cert_fp" && "$key_fp" != "$cert_fp" ]]; then
                rm -f "$host_cert"
              fi
            fi
            ssh-add -q "$state_keys_dir/host" </dev/null >/dev/null 2>&1 || true
          fi
        fi
      fi
    '';
  };

  # Configure system zsh shells to initialize keychain automatically
  programs.zsh = {
    enable = true;
    interactiveShellInit = ''
      state_keys_dir="${XDG_STATE_HOME:-$HOME/.local/state}/ssh-keys.d"
      if command -v keychain >/dev/null 2>&1 && [[ -f "$state_keys_dir/host" ]]; then
        eval "$(keychain --quiet --eval "$state_keys_dir/host")"

        if command -v ssh-add >/dev/null 2>&1; then
          ssh-add -l >/dev/null 2>&1
          if [[ $? -eq 2 ]]; then
            unset SSH_AUTH_SOCK SSH_AGENT_PID
            eval "$(keychain --quiet --eval "$state_keys_dir/host")"

            ssh-add -l >/dev/null 2>&1
            if [[ $? -eq 2 ]] && command -v launchctl >/dev/null 2>&1; then
              launchd_sock="$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true)"
              if [[ -n "$launchd_sock" ]]; then
                export SSH_AUTH_SOCK="$launchd_sock"
                unset SSH_AGENT_PID
              fi
            fi
          fi

          ssh-add -l >/dev/null 2>&1
          if [[ $? -eq 1 ]]; then
            host_key="$state_keys_dir/host"
            host_cert="$state_keys_dir/host-cert.pub"
            if [[ -f "$host_key" && -f "$host_cert" ]]; then
              key_fp="$(ssh-keygen -lf "$host_key" 2>/dev/null | awk '{print $2}' || true)"
              cert_fp="$(ssh-keygen -Lf "$host_cert" 2>/dev/null | awk '/Public key:/ {print $4; exit}' || true)"
              if [[ -n "$key_fp" && -n "$cert_fp" && "$key_fp" != "$cert_fp" ]]; then
                rm -f "$host_cert"
              fi
            fi
            ssh-add -q "$state_keys_dir/host" </dev/null >/dev/null 2>&1 || true
          fi
        fi
      fi
    '';
  };
}
