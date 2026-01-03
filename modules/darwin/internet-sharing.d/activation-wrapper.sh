#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
	echo "[internetSharing] configuring Internet Sharing NAT"
	@configurePlist@

	@verifyAnchorsBlock@
}

activation_run darwin.activationScripts.networking.internet-sharing-activation main "$@"
