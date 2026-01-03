#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
	echo "[google-updaters] Disabling Google update services"
	@disableGoogleUpdatersScript@/bin/disable-google-updaters
}

activation_run darwin.activationScripts.postActivation.disable-google-updaters main "$@"
