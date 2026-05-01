#!/usr/bin/env -S bash -euo pipefail
# shellcheck source=/dev/null
source @nixBashTrampoline@

main() {
  set -euxo pipefail

  root_fs_type="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  root_fs_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if [[ "$root_fs_type" != "zfs" ]] || [[ "$root_fs_source" != tank/* ]]; then
    : "[esp-sync][INFO] skip: root filesystem is not tank zfs (source=${root_fs_source:-unknown} fstype=${root_fs_type:-unknown})"
    exit 0
  fi

  primary_esp_part_label="${PRIMARY_ESP_PART_LABEL:-esp-boot}"
  primary_esp="${PRIMARY_ESP_MOUNT:-/boot}"
  secondary_esp_part_labels="${SECONDARY_ESP_PART_LABELS:-esp-tank1 esp-tank2 esp-tank3 esp-recover}"
  esp_parts=()

  if [[ ! -d "$primary_esp" ]]; then
    : "[esp-sync][INFO] skip: primary ESP mount not present at $primary_esp"
    exit 0
  fi

  if ! mountpoint -q "$primary_esp"; then
    : "[esp-sync][INFO] skip: primary ESP is not mounted"
    exit 0
  fi

  read -r -a configured_labels <<< "$secondary_esp_part_labels"
  for esp_label in "${configured_labels[@]}"; do
    if [[ "$esp_label" == "$primary_esp_part_label" ]]; then
      continue
    fi

    esp_part="/dev/disk/by-partlabel/${esp_label}"
    if [[ ! -e "$esp_part" ]]; then
      : "[esp-sync][INFO] skip missing configured ESP partition: $esp_part"
      continue
    fi

    esp_parts+=("$esp_part")
  done

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
