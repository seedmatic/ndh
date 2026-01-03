#!/usr/bin/env -S bash -xeuo pipefail
install -d -m 750 -o root -g nixbld @builderKeyDir@
install -m 640 -o root -g nixbld @builderPrivStore@ @builderKeyPath@
install -m 644 -o root -g nixbld @builderPubStore@ @builderKeyPath@.pub
