#!/bin/bash

# Mount a volatile, case-sensitive tmpfs at $1 (size cap $2) and publish it as
# the user's TMPDIR, idempotently. Belt-1 of the operator-scratch model: the
# machine owns the volatile backing (Felix bundle cache ~64 MiB, manifests
# synthesis); consumers still sweep their own temp. Invoked by the tmpdir-tmpfs
# LaunchAgent at login (gui/<uid> domain, as the user).

set -eu -o pipefail

MP="${1:?mount point required}"
SIZE="${2:-4g}"
OWNER="$(/usr/bin/id -un)"

# Publish TMPDIR into the user launchd session (gui/<uid>) so GUI-launched
# processes inherit the tmpfs too — not just login shells (which get it via
# hm-session-vars; ssh shells rely on that path, never entering gui/<uid>).
# Runs as the user, so it must precede the privileged mount below.
/bin/launchctl setenv TMPDIR "$MP"

# The mount point must exist as a plain on-disk dir so TMPDIR stays valid even
# when the tmpfs is absent; the volume simply overlays it.
/bin/mkdir -p "$MP"

# Idempotent: a tmpfs already mounted here means we are done.
if /sbin/mount | /usr/bin/grep -q " on $MP (tmpfs"; then
  echo "tmpdir-tmpfs: already mounted at $MP (TMPDIR published)"
  exit 0
fi

# mount_tmpfs needs root; run just the privileged steps under sudo (nxmatic has
# NOPASSWD — modules/darwin/security.nix). -n so a missing NOPASSWD fails fast
# instead of blocking a TTY-less login. -e makes the volume case-sensitive
# (macOS mount_tmpfs defaults to case-INSENSITIVE); -s caps total size.
/usr/bin/sudo -n /sbin/mount_tmpfs -e -s "$SIZE" "$MP"

# The fresh volume root is root:wheel; hand it to the operator, private mode.
/usr/bin/sudo -n /usr/sbin/chown "$OWNER:staff" "$MP"
/usr/bin/sudo -n /bin/chmod 0700 "$MP"

echo "tmpdir-tmpfs: mounted case-sensitive tmpfs ($SIZE) at $MP for $OWNER; TMPDIR published"
