#!/usr/bin/env -S bash -euo pipefail
LOG="/var/log/darwin-openssh-post-activation.log"
install -d -m 755 /var/log
exec >>"$LOG" 2>&1
set -x

"@opensshActivationScript@"
