#!/bin/bash

# Reap abandoned files from the operator's tmpfs scratch. Runs periodically via
# the tmpdir-tmpfs-reap LaunchAgent. A RAM-backed tmpfs only reclaims space at
# reboot, so between reboots we delete regular files that for more than N days
# were neither read (atime) nor modified (mtime) AND that no live process holds
# open (lsof) — the strictest "truly abandoned" test macOS offers, matching how
# it reaps /var/folders. Most apps close temp files rather than hold them open,
# so atime/mtime is the real guard and lsof only covers the long-lived-fd edge.
# @lsof@ is pinned by nix (modules/home-manager/tmpdir-tmpfs.nix).

set -eu -o pipefail

MP="${1:?mount point required}"
DAYS="${2:-3}"

[ -d "$MP" ] || exit 0

# One lsof pass: snapshot every path currently open under MP (any fd, any type).
# Conservative — a path listed here is never deleted. `|| true` because lsof
# exits non-zero when some entries can't be stat'd, which is expected.
open_set="$(/usr/bin/mktemp)"
trap '/bin/rm -f "$open_set"' EXIT
@lsof@ -Fn +D "$MP" 2>/dev/null | /usr/bin/sed -n 's/^n//p' | /usr/bin/sort -u >"$open_set" || true

# Delete regular files neither read (atime) nor modified (mtime) in more than
# DAYS days and not currently held open. Requiring BOTH atime and mtime stale
# only ever protects more files than mtime alone — a file still being read
# keeps a fresh atime and survives.
reaped=0
while IFS= read -r -d '' f; do
  if ! /usr/bin/grep -qxF -- "$f" "$open_set"; then
    /bin/rm -f "$f" && reaped=$((reaped + 1))
  fi
done < <(/usr/bin/find "$MP" -type f -atime +"$DAYS" -mtime +"$DAYS" -print0)

# Prune directories left empty by the sweep (never MP itself).
/usr/bin/find "$MP" -mindepth 1 -type d -empty -delete 2>/dev/null || true

echo "tmpdir-reap: swept ${reaped} stale unopened file(s) under ${MP} (>${DAYS}d)"
