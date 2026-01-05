#!/usr/bin/env -S bash -euo pipefail

source @activationLogger@

main() {
	control_dir="@controlMasterDir@"
	mkdir -p "$control_dir"
	chown root:nixbld "$control_dir"
	chmod 0775 "$control_dir"
}

activation_run darwin.activationScripts.distributed-builds.ensure-control-path main "$@"
