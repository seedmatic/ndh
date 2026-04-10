#!/usr/bin/env -S bash -euo pipefail
source @logger@

main() {
	echo "[google-updaters] Disabling Google update services"
	@disableGoogleUpdatersScript@/bin/disable-google-updaters
}

ndh::logger:command:run darwin.activationScripts.postActivation.disable-google-updaters main "$@"
