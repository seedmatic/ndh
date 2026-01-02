#!/usr/bin/env -S bash -xeuo pipefail

/sbin/nfsd enable || true
if /sbin/nfsd status >/dev/null 2>&1; then
  /sbin/nfsd restart
else
  /sbin/nfsd start
fi
