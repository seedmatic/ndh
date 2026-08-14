#!/bin/bash

# Mount a volatile, case-sensitive tmpfs at $1 (size cap $2), idempotently.
# Belt-1 of the operator-scratch model: the machine owns the volatile backing
# of the operator's TMPDIR; consumers (Felix bundle cache, manifests synthesis)
# still sweep their own temp. Invoked by the tmpdir-tmpfs LaunchAgent at login.

set -eu -o pipefail

MP="${1:?mount point required}"
SIZE="${2:-4g}"
OWNER="${SUDO_USER:-$USER}"

# mount_tmpfs needs root; re-exec under sudo (nxmatic has NOPASSWD, see
# modules/darwin/security.nix). -n so a missing NOPASSWD fails fast instead of
# blocking a TTY-less login on a password prompt.
if [ "$EUID" -ne 0 ]; then
  exec /usr/bin/sudo -n "$0" "$@"
fi

# The mount point must exist as a plain on-disk dir so TMPDIR stays valid even
# when the tmpfs is absent; the volume simply overlays it.
/bin/mkdir -p "$MP"

# Idempotent: a tmpfs already mounted here means we are done.
if /sbin/mount | /usr/bin/grep -q " on $MP (tmpfs"; then
  echo "tmpdir-tmpfs: already mounted at $MP"
  exit 0
fi

# -e makes the volume case-sensitive (macOS mount_tmpfs defaults to
# case-INSENSITIVE); -s caps total size (RAM+swap is only used as written).
/sbin/mount_tmpfs -e -s "$SIZE" "$MP"

# The fresh volume root is root:wheel; hand it to the operator, private mode.
/usr/sbin/chown "$OWNER:staff" "$MP"
/bin/chmod 0700 "$MP"

echo "tmpdir-tmpfs: mounted case-sensitive tmpfs ($SIZE) at $MP for $OWNER"
