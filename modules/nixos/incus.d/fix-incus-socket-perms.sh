#!/usr/bin/env -S bash -euo pipefail
# Fix Incus socket permissions to allow non-root access
find /run/incus -type f -exec chmod g+rw {} +
find /run/incus -type d -exec chmod g+rwx {} +
