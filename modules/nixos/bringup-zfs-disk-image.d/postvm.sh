# shellcheck shell=bash
# bringup-zfs-disk-image postVM - cleanup and output collection
#
# Runs on linux-builder after QEMU exits. Performs:
#   - Move disk images to $out
#   - Collect observability YAML files from xchg/
#   - Kill Vector relay socat process
#
# ENVIRONMENT:
#   _NDH_VECTOR_RELAY_PID - PID of socat relay process (from preVM)
#   NDH_NIXOS_NAME        - Short hostname label for PS4 logging
#   (Disk image vars exported from wrapper)
#
# OUTPUT:
#   $out/boot.img                           - Boot disk image
#   $out/{tank1,tank2,tank3,recover}.img    - ZFS disk images
#   $out/boot-size-hint.yaml                - Boot partition size metadata (if exists)

set -eo pipefail
PS4="[${NDH_NIXOS_NAME:-nixos}:bringup-postVM:\${LINENO}] "
set -x

# Move disk images (bootDiskImage and ZFS disk vars are exported by wrapper)
# Note: this script is called with disk image variables already in scope
