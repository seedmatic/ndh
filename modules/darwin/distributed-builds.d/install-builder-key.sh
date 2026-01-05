#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
	install -d -m 750 -o root -g nixbld @builderKeyDir@
	install -m 444	-o root -g nixbld @builderPrivStore@ @builderKeyPath@
	install -m 444 -o root -g nixbld @builderPubStore@ @builderKeyPath@.pub
}

activation_run darwin.activationScripts.etc.distributed-builds main "$@"
