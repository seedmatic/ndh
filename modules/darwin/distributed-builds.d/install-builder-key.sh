#!/usr/bin/env -S bash -euo pipefail
source @logger@

main() {
	install -d -m 750 -o root -g nixbld @builderKeyDir@
	install -m 444	-o root -g nixbld @builderPrivStore@ @builderKeyPath@
	install -m 444 -o root -g nixbld @builderPubStore@ @builderKeyPath@.pub
}

ndh::logger:command:run darwin.activationScripts.etc.distributed-builds main "$@"
