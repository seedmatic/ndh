#!/usr/bin/env -S bash -euo pipefail
source @logger@

main() {
  echo "[spotlight] Disabling Spotlight indexing and cleaning stale indexes"
  @disableSpotlightScript@/bin/disable-spotlight
}

ndh::logger:command:run darwin.activationScripts.postActivation.disable-spotlight main "$@"