#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  echo "[spotlight] Disabling Spotlight indexing and cleaning stale indexes"
  @disableSpotlightScript@/bin/disable-spotlight
}

activation_run darwin.activationScripts.postActivation.disable-spotlight main "$@"