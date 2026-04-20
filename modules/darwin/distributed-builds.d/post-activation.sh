#!/usr/bin/env -S bash -euo pipefail

source @nixBashTrampoline@

main() {
  @builderKeyInstall@
  @installAuthorizedKeys@
  @controlPathScript@
}

ndh::logger:command:run darwin.activationScripts.distributed-builds.post main "$@"
