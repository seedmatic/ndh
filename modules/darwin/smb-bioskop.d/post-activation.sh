#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
	@bioskopFstabScript@
}

ndh::logger:command:run darwin.activationScripts.etc.smb-bioskop main "$@"
