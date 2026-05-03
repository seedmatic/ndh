#!/usr/bin/env -S bash -euo pipefail

# Home-manager activation: fix ownership of $HOME config files and dirs
# created by root during bringup so that subsequent user-mode activation
# can create symlinks inside them. (@codebase)
source @nixBashTrampoline@

main() {
  set -euo pipefail

  LOGGER_BIN=${LOGGER_BIN:-/usr/bin/logger}

  WRAPPERS="/run/wrappers/bin"
  if [ -d "$WRAPPERS" ]; then
    case ":$PATH:" in
      *":$WRAPPERS:"*) ;;
      *) PATH="$WRAPPERS:$PATH" ;;
    esac
  fi

  if [ "$(id -u)" -ne 0 ]; then
    if [ -x "$WRAPPERS/sudo" ]; then
      SUDO="$WRAPPERS/sudo -n"
      $SUDO true 2>/dev/null || SUDO="$WRAPPERS/sudo"
    elif command -v sudo >/dev/null 2>&1; then
      SUDO="sudo -n"
      $SUDO true 2>/dev/null || SUDO="sudo"
    else
      SUDO=""
    fi
  else
    SUDO=""
  fi

  # Ensure the user owns their own home tree.  During bringup the activation
  # script runs as root, leaving files and directories owned by root.
  # home-manager's linkGeneration step runs as the user and cannot create
  # symlinks into root-owned directories, so we fix that here.
  local home="$HOME"
  local user
  user="$(id -un)"

  # Fix ownership of well-known dotfiles created by a root-owned HM generation.
  for f in \
    "$home/.bash_profile" "$home/.bashrc" "$home/.profile" \
    "$home/.zshenv" "$home/.zshrc" "$home/.zprofile" \
    "$home/.dir_colors" "$home/.config" "$home/.local/state/home-manager"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      current_owner="$(stat -c '%U' "$f" 2>/dev/null || echo unknown)"
      if [ "$current_owner" != "$user" ]; then
        $SUDO chown -Rh "$user:" "$f"
      fi
    fi
  done
}

ndh::logger:command:run "@loggerTag@" main "$@"
