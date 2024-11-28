#!/bin/bash

# Function to create or update the disk image
dmg:createOrUpdate() {
  if [ -f "$DMG" ]; then
    shadow:detachAll
    rm -f "$DMG"
  fi

  hdiutil create -owners on -fs APFS -volname "m2-base-repo" \
    -srcfolder "$BASE" "$DMG"
}

# Function to build the yq expression
shadow:detach:filter() {
  local dmg="$1"
    cat <<! | cut -c 7-
      .images[] | 
        select( .image-path == "$dmg" ) |
        .system-entities[] |
        .mount-point
!
}

# Function to detach all mounted images
shadow:detachAll() {
  local expression
  expression="$( shadow:detach:filter "$DMG" )"
  hdiutil info -plist | 
    plutil -convert json -o - - |
    yq -p json -r -o yaml "$expression" - |
    while read -r mountpoint; do
    shadow:detach "$mountpoint"
  done
  dmg:eject
}

# Function to eject the DMG
dmg:eject() {
  hdiutil eject "$DMG"
}

# Function to mount a shadowed folder
dmg:mount() {
  local mountpoint="$1"
  local shadow="${2:-}"

  # Skip if the mount point does not exist
  [[ ! -d "$mountpoint" ]] && return 1

  # Mount the shadowed image
  shadow:attach "$mountpoint" "$shadow"
}

# Function to attach a shadow to a mount point
shadow:attach() {
  local mountpoint="$1"
  local shadow="$2"
  local opts=(  "${HDI_ATTACH_OPTS[@]}" )

  [[ -n "$shadow" ]] && opts+=( "-shadow" "$shadow" )

  hdiutil attach "${opts[@]}" -mountpoint "$mountpoint" "$DMG"
}

# Function to detach a shadow from a mount point
shadow:detach() {
  local mountpoint="$1"
  shadow:is_mounted "$mountpoint" && 
    return
  umount "$mountpoint"
}

# Function to check if a mount point is currently mounted
shadow:is_mounted() {
  local mountpoint="$1"

  hdiutil info -plist | plutil -convert json -o - - | yq -e '.images[].system-entities[] | select(.mount-point == "'"$mountpoint"'") | .mount-point' > /dev/null 2>&1
}

# Function to mount shadowed folders
folders:mount() {
  for mountpoint in "$@"; do
    dmg:mount "$mountpoint" "${mountpoint}.shadow"
  done
}

# Check if we are sourcing the file
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

# Check if we have any arguments
[[ $# -eq 0 ]] && exit 0

# Exit on error and log the commands
set -ex -o pipefail

# Check if the script is running as root
if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.local/var/cache}"

BASE="${MAVEN_LOCAL_REPOSITORY:-$XDG_CACHE_HOME/m2/repository}"
BASE="$( realpath "$BASE" )"
DMG="${BASE}.dmg"
HDI_ATTACH_OPTS=( "-noverify" "-nobrowse" "-readwrite" "-noautoopen" )
 
# Main script execution
dmg:createOrUpdate
folders:mount "$@"
