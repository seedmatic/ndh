#!/usr/bin/env -S bash -euo pipefail

log() {
  /bin/echo "[disable-spotlight] $*"
}

is_skipped_mountpoint() {
  case "$1" in
    /System*|/private*|/dev*|/net*|/Network*|/home|/Volumes/Preboot|/Volumes/Update|/Volumes/VM|/Volumes/com.apple.TimeMachine.localsnapshots)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

list_mountpoints() {
  /bin/echo "/"
  if [ -d /Volumes ]; then
    /usr/bin/find /Volumes -mindepth 1 -maxdepth 1 -type d -print | /usr/bin/sort
  fi
}

disable_and_cleanup_volume() {
  local mountpoint="$1"

  if [ ! -d "$mountpoint" ]; then
    return 0
  fi

  if is_skipped_mountpoint "$mountpoint"; then
    log "Skipping protected mountpoint: $mountpoint"
    return 0
  fi

  log "Disabling Spotlight indexing: $mountpoint"
  /usr/bin/mdutil -i off "$mountpoint" >/dev/null 2>&1 || log "mdutil disable failed for $mountpoint"

  log "Erasing Spotlight index metadata: $mountpoint"
  /usr/bin/mdutil -E "$mountpoint" >/dev/null 2>&1 || log "mdutil erase failed for $mountpoint"

  if [ -e "$mountpoint/.Spotlight-V100" ]; then
    log "Removing Spotlight index store: $mountpoint/.Spotlight-V100"
    /bin/rm -rf "$mountpoint/.Spotlight-V100" || log "Failed to remove $mountpoint/.Spotlight-V100"
  fi

  # Prevent future indexing metadata creation on this volume.
  /usr/bin/touch "$mountpoint/.metadata_never_index" >/dev/null 2>&1 ||
    log "Failed to create $mountpoint/.metadata_never_index"
}

main() {
  while IFS= read -r mountpoint; do
    disable_and_cleanup_volume "$mountpoint"
  done < <(list_mountpoints | /usr/bin/awk '!seen[$0]++')
}

main "$@"