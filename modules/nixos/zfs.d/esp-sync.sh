#!/usr/bin/env -S bash -euo pipefail
# shellcheck source=/dev/null
source @bashTrampoline@
# shellcheck source=/dev/null
source @logger@

main() {
  set -euxo pipefail

  primary_esp="/boot/efi"
  if [[ ! -d "$primary_esp" ]]; then
    : "[esp-sync][INFO] skip: primary ESP mount not present at $primary_esp"
    exit 0
  fi

  if ! mountpoint -q "$primary_esp"; then
    : "[esp-sync][INFO] skip: primary ESP is not mounted"
    exit 0
  fi

  mapfile -t esp_parts < <(find /dev/disk/by-partlabel -maxdepth 1 -type l -name 'esp[0-9]*' | sort)
  if [[ "${#esp_parts[@]}" -eq 0 ]]; then
    : "[esp-sync][INFO] skip: no additional ESP partitions found"
    exit 0
  fi

  for esp_part in "${esp_parts[@]}"; do
    if [[ ! -b "$esp_part" ]]; then
      continue
    fi

    fs_type="$(blkid -o value -s TYPE "$esp_part" 2>/dev/null || true)"
    if [[ -z "$fs_type" ]]; then
      : "[esp-sync][INFO] formatting uninitialized ESP partition: $esp_part"
      mkfs.vfat -F 32 -n NIXBOOT "$esp_part"
    elif [[ "$fs_type" != "vfat" ]]; then
      : "[esp-sync][WARN] skip non-vfat partition: $esp_part (type=$fs_type)"
      continue
    fi

    target_mount="/run/esp-sync/$(basename "$esp_part")"
    mkdir -p "$target_mount"
    mount -t vfat "$esp_part" "$target_mount"
    cp -a "$primary_esp/." "$target_mount/"
    sync
    umount "$target_mount"
    rmdir "$target_mount"
    : "[esp-sync][INFO] mirrored primary ESP -> $esp_part"
  done
}

ndh::logger:command:run "nixos.zfs.esp-sync" main "$@"
