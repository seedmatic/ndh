#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
	echo "[internetSharing] configuring Internet Sharing NAT"
	@configurePlist@

	@verifyAnchorsBlock@
}

ndh::logger:command:run darwin.activationScripts.networking.internet-sharing-activation main "$@"
