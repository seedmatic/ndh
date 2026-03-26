#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  echo "[agents] Disabling optional unwanted background agents"
  @disableUnwantedAgentsScript@/bin/disable-unwanted-agents
}

activation_run darwin.activationScripts.postActivation.disable-unwanted-agents main "$@"