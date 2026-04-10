#!/usr/bin/env -S bash -euo pipefail

# Home-manager activation: prepare sudo wrapper path resolution (@codebase)
source @logger@

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
}

ndh::logger:command:run "@activationTag@" main "$@"
