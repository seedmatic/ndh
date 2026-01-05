#!/usr/bin/env -S bash -euo pipefail
# Shared post-activation wrapper (@codebase)
# Platform layers (darwin/nixos) must provide activation-logger.sh.

source @activationLogger@

main() {
  HM_ACTIVATE="@hmActivationPackage@/activate"
  if [ -n "$HM_ACTIVATE" ] && [ -x "$HM_ACTIVATE" ]; then
    sudo -u @userName@ HOME="@userHome@" XDG_RUNTIME_DIR="@userHome@/.xdg" "$HM_ACTIVATE"
  else
    echo "home-manager activation package missing for @userName@, skipping" >&2
  fi
}

activation_run "@activationTag@" main "$@"
