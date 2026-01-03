#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
	@bioskopFstabScript@
}

activation_run darwin.activationScripts.etc.smb-bioskop main "$@"
