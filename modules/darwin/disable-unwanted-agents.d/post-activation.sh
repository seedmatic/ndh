#!/usr/bin/env -S bash -euo pipefail
source @logger@

main() {
  echo "[agents] Disabling optional unwanted background agents"
  @disableUnwantedAgentsScript@/bin/disable-unwanted-agents
}

ndh::logger:command:run darwin.activationScripts.postActivation.disable-unwanted-agents main "$@"