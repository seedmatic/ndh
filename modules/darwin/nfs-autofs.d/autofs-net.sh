#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
	export MOUNT_POINT=@mountPoint@
	export MAP=@map@
	export OPTIONS=@options@
	export MANAGE_AUTO_MASTER=@manageAutoMaster@
	"@autofsRefreshScript@"
}

activation_run darwin.activationScripts.etc.nfs-autofs-net main "$@"
