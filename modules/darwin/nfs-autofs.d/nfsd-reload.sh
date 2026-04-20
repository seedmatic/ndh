#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
  /sbin/nfsd enable || true
  if /sbin/nfsd status >/dev/null 2>&1; then
    /sbin/nfsd restart
  else
    /sbin/nfsd start
  fi
}

ndh::logger:command:run darwin.activationScripts.etc.nfsd-reload main "$@"
