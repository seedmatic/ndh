#!/usr/bin/env -S bash -xeuo pipefail
set -euo pipefail

export MOUNT_POINT=@mountPoint@
export MAP=@map@
export OPTIONS=@options@
export MANAGE_AUTO_MASTER=@manageAutoMaster@
"@autofsRefreshScript@"
