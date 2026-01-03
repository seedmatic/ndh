#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  /sbin/nfsd enable || true
  if /sbin/nfsd status >/dev/null 2>&1; then
    /sbin/nfsd restart
  else
    /sbin/nfsd start
  fi
}

activation_run darwin.activationScripts.etc.nfsd-reload main "$@"
