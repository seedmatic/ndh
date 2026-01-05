#!/usr/bin/env -S bash -euo pipefail

source @activationLogger@

main() {
  @builderKeyInstall@
  @installAuthorizedKeys@
  @controlPathScript@
}

activation_run darwin.activationScripts.distributed-builds.post main "$@"
