#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
	ln -sfn /etc/static/auto_master /etc/auto_master
}

activation_run darwin.activationScripts.etc.auto-master-link main "$@"
