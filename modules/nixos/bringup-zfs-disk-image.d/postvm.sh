# shellcheck shell=bash
# bringup-zfs-disk-image postVM — cleanup and output collection
#
# Runs on linux-builder after QEMU exits. Performs:
#   - Move disk images to $out
#   - Collect observability YAML files from xchg/
#   - Kill Vector relay socat process
#   - Run user-provided postVM commands
#
# ENVIRONMENT:
#   _NDH_VECTOR_RELAY_PID   — PID of socat relay process (from preVM)
#   bootDiskImage           — Boot disk filename
#   postVmMoveDiskImages    — Commands to move ZFS disk images to output
#   postVmUserCommands      — User-provided postVM commands
#
# OUTPUT:
#   $out/boot.img                           — Boot disk image
#   $out/{tank1,tank2,tank3,recover}.img    — ZFS disk images
#   $out/boot-size-hint.yaml                — Boot partition size metadata (if exists)

set -eo pipefail

mv "$bootDiskImage" "$out/boot.img"
@postVmMoveDiskImages@

if [[ -f xchg/boot-size-hint.yaml ]]; then
  mv xchg/boot-size-hint.yaml "$out/boot-size-hint.yaml"
fi

[[ -n "${_NDH_VECTOR_RELAY_PID:-}" ]] && kill "${_NDH_VECTOR_RELAY_PID}" 2>/dev/null || true

PS4='[bringup-postVM:${LINENO}] '
set -x
@postVmUserCommands@
