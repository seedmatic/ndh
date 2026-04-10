#!/usr/bin/env -S bash -euo pipefail
source @logger@

main() {
	echo "[internetSharing] configuring Internet Sharing NAT"
	@configurePlist@

	@verifyAnchorsBlock@
}

ndh::logger:command:run darwin.activationScripts.networking.internet-sharing-activation main "$@"
