#!/usr/bin/env -S bash -euo pipefail
source @logger@

main() {
	echo "[dnsmasq] Ensuring log path @logFile@"
	mkdir -p "$(dirname @logFile@)"
	touch "@logFile@"
	chmod 644 "@logFile@"
	chown @userName@:staff "@logFile@"
}

ndh::logger:command:run darwin.activationScripts.postActivation.dnsmasq main "$@"
