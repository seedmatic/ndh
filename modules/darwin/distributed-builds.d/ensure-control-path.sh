#!/usr/bin/env -S bash -euo pipefail

source @nixBashTrampoline@

main() {
	control_dir="@controlMasterDir@"
	mkdir -p "$control_dir"
	chown root:nixbld "$control_dir"
	chmod 0775 "$control_dir"
}

ndh::logger:command:run darwin.activationScripts.distributed-builds.ensure-control-path main "$@"
