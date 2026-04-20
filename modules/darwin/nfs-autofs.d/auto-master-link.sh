#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
	ln -sfn /etc/static/auto_master /etc/auto_master
}

ndh::logger:command:run darwin.activationScripts.etc.auto-master-link main "$@"
