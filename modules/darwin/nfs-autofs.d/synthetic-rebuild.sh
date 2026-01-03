#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  if [ -x /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util ]; then
    # macOS synthetic objects are rebuilt with -t (stitch) on modern APFS
    /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t || true
  fi
}

activation_run darwin.activationScripts.etc.nfs-synthetic-rebuild main "$@"
