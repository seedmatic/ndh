#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
	export MOUNT_POINT=@mountPoint@
	export MAP=@map@
	export OPTIONS=@options@
	export MANAGE_AUTO_MASTER=@manageAutoMaster@
	"@autofsRefreshScript@"
}

ndh::logger:command:run darwin.activationScripts.etc.nfs-autofs-net main "$@"
