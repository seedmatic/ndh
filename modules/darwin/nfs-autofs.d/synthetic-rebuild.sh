#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
  if [ -x /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util ]; then
    # macOS synthetic objects are rebuilt with -t (stitch) on modern APFS
    /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t || true
  fi
}

ndh::logger:command:run darwin.activationScripts.etc.nfs-synthetic-rebuild main "$@"
