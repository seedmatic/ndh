#!/usr/bin/env -S bash -euo pipefail
# shellcheck source=/dev/null
source @nixBashTrampoline@

zfs::obs:enabled() {
  [[ "${NDH_ZFS_INSTALL_OBSERVE:-1}" == "1" ]]
}

zfs::obs:log() {
  : "[zfs-nixos-install][obs] $*"
}

zfs::obs:sample() {
  zfs::obs:log "sample ts=$(date -Iseconds)"
  zfs::obs:log "sample root_mounts"
  findmnt -rno SOURCE,TARGET,FSTYPE 2>/dev/null | awk '$2 ~ /^\/$|^\/boot$|^\/nix$|^\/mnt\// { print }' || true
  zfs::obs:log "sample diskstats"
  awk '$3 ~ /^(vd|sd|nvme)/ {print $3, $6, $10, $14}' /proc/diskstats 2>/dev/null || true
  zfs::obs:log "sample dirty_writeback"
  awk '/^(Dirty|Writeback):/ {print}' /proc/meminfo 2>/dev/null || true
  if command -v iostat >/dev/null 2>&1; then
    zfs::obs:log "sample iostat"
    iostat -dx 1 1 2>/dev/null || true
  fi
  if command -v ps >/dev/null 2>&1; then
    zfs::obs:log "sample top_cpu"
    ps -eo pid,ppid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 12 || true
  fi
}

zfs::obs:start() {
  zfs::obs:enabled || return 0
  local interval="${NDH_ZFS_INSTALL_OBSERVE_INTERVAL:-2}"
  local obs_log_file="${NDH_ZFS_INSTALL_OBSERVE_LOG:-/var/log/ndh/zfs-nixos-install-observe.log}"
  mkdir -p "$(dirname "$obs_log_file")"
  zfs::obs:log "start interval=${interval}s log=${obs_log_file}"
  (
    while true; do
      zfs::obs:sample
      sleep "$interval"
    done
  ) >>"$obs_log_file" 2>&1 &
  NDH_ZFS_INSTALL_OBS_PID="$!"
  export NDH_ZFS_INSTALL_OBS_PID
}

zfs::obs:stop() {
  zfs::obs:enabled || return 0
  if [[ -n "${NDH_ZFS_INSTALL_OBS_PID:-}" ]] && kill -0 "${NDH_ZFS_INSTALL_OBS_PID}" 2>/dev/null; then
    zfs::obs:log "stop pid=${NDH_ZFS_INSTALL_OBS_PID}"
    kill "${NDH_ZFS_INSTALL_OBS_PID}" 2>/dev/null || true
    wait "${NDH_ZFS_INSTALL_OBS_PID}" 2>/dev/null || true
  fi
}

zfs::obs:mark() {
  zfs::obs:enabled || return 0
  local label="$1"
  zfs::obs:log "phase=${label}"
}

zfs::guard:mountpoint:check() {
  local install_root_mount_point="$1"
  if ! mountpoint -q "$install_root_mount_point"; then
    : "[zfs-nixos-install][ERROR] expected disko target mountpoint missing: $install_root_mount_point"
    return 1
  fi
  return 0
}

zfs::flake:root:require() {
  local ndh_top_level_mount_point="$1"

  if [[ ! -r "${ndh_top_level_mount_point}/flake.nix" ]]; then
    : "[zfs-nixos-install][ERROR] canonical NDH flake root missing/unreadable: ${ndh_top_level_mount_point}/flake.nix"
    return 1
  fi

  realpath -e "$ndh_top_level_mount_point"
  return 0
}

zfs::boot:sync:bringup:to:target() {
  local install_root_mount_point="$1"
  local bringup_boot_source="${BRINGUP_BOOT_MOUNT:-/boot}"
  local target_boot_mount="${install_root_mount_point}/boot"
  local bringup_boot_dev=""
  local target_boot_dev=""

  if ! mountpoint -q "$target_boot_mount"; then
    : "[zfs-nixos-install][ERROR] target boot mountpoint unavailable: $target_boot_mount"
    return 1
  fi

  if ! mountpoint -q "$bringup_boot_source"; then
    : "[zfs-nixos-install][ERROR] bringup boot mountpoint unavailable: $bringup_boot_source"
    return 1
  fi

  bringup_boot_dev="$(findmnt -n -o SOURCE "$bringup_boot_source" 2>/dev/null || true)"
  target_boot_dev="$(findmnt -n -o SOURCE "$target_boot_mount" 2>/dev/null || true)"

  if [[ -n "$bringup_boot_dev" && -n "$target_boot_dev" && "$bringup_boot_dev" == "$target_boot_dev" ]]; then
    : "[zfs-nixos-install] skip boot sync: bringup and target boot mounts are same device ($target_boot_dev)"
    return 0
  fi

  : "[zfs-nixos-install] initializing target boot from bringup mount: src=$bringup_boot_source dst=$target_boot_mount"
  cp -a "$bringup_boot_source/." "$target_boot_mount/"
  sync
}

zfs::boot:sync:target:to:bringup() {
  local install_root_mount_point="$1"
  local bringup_boot_mount="${BRINGUP_BOOT_MOUNT:-/boot}"
  local target_boot_source="${install_root_mount_point}/boot"
  local bringup_boot_dev=""
  local target_boot_dev=""

  if ! mountpoint -q "$target_boot_source"; then
    : "[zfs-nixos-install][ERROR] target boot mountpoint unavailable: $target_boot_source"
    return 1
  fi

  if ! mountpoint -q "$bringup_boot_mount"; then
    : "[zfs-nixos-install][ERROR] bringup boot mountpoint unavailable: $bringup_boot_mount"
    return 1
  fi

  target_boot_dev="$(findmnt -n -o SOURCE "$target_boot_source" 2>/dev/null || true)"
  bringup_boot_dev="$(findmnt -n -o SOURCE "$bringup_boot_mount" 2>/dev/null || true)"

  if [[ -n "$target_boot_dev" && -n "$bringup_boot_dev" && "$target_boot_dev" == "$bringup_boot_dev" ]]; then
    : "[zfs-nixos-install] skip boot sync: target and bringup boot mounts are same device ($target_boot_dev)"
    return 0
  fi

  : "[zfs-nixos-install] syncing target boot back to bringup mount: src=$target_boot_source dst=$bringup_boot_mount"
  cp -a "$target_boot_source/." "$bringup_boot_mount/"
  sync
}

zfs::nixos:install:run() {
  local install_root_mount_point="$1"
  local flake_root="$2"
  local nixos_config_name="$3"
  local flake_ref="${flake_root}#${nixos_config_name}"
  local chroot_flake_root="${flake_root}"
  local host_flake_root=""

  zfs::obs:mark "nixos-install-flake:start"
  : "[zfs-nixos-install] installing runtime system to ${install_root_mount_point} from flake: $flake_ref"
  nixos-install \
    --option accept-flake-config true \
    --option experimental-features "nix-command flakes" \
    --root "$install_root_mount_point" \
    --flake "$flake_ref" \
    --no-root-passwd \
    --no-bootloader \
    --verbose
  zfs::obs:mark "nixos-install-flake:done"

  zfs::obs:mark "nixos-rebuild-boot-in-chroot:start"
  : "[zfs-nixos-install] nixos-install complete, performing final switch-to-configuration in chrooted environment"
  host_flake_root="$(realpath -e "${flake_root}")"
  mkdir -p "${install_root_mount_point}${chroot_flake_root}"
  mount --bind "${host_flake_root}" "${install_root_mount_point}${chroot_flake_root}"
  if ! cat <<EOF | cut -c 2- | nixos-enter --root "$install_root_mount_point"
    set -exuo pipefail
    PATH="/nix/var/nix/profiles/system/sw/bin:\${PATH}"
    nixos-rebuild --accept-flake-config boot --flake "${chroot_flake_root}#${nixos_config_name}"
EOF
  then
    umount "${install_root_mount_point}${chroot_flake_root}" || true
    : "[zfs-nixos-install][ERROR] chrooted nixos-rebuild boot failed"
    return 1
  fi
  umount "${install_root_mount_point}${chroot_flake_root}" || true
  zfs::obs:mark "nixos-rebuild-boot-in-chroot:done"

}

zfs::nixos:install:prebuilt:run() {
  local install_root_mount_point="$1"
  local prebuilt_system_path="$2"
  local copy_from_store="$3"

  if [[ -n "$copy_from_store" ]]; then
    zfs::obs:mark "nix-copy-prebuilt:start"
    : "[zfs-nixos-install] copying prebuilt system closure from ${copy_from_store}: ${prebuilt_system_path}"
    nix copy --from "$copy_from_store" "$prebuilt_system_path"
    zfs::obs:mark "nix-copy-prebuilt:done"
  fi

  zfs::obs:mark "nixos-install-prebuilt:start"
  : "[zfs-nixos-install] installing prebuilt system to ${install_root_mount_point}: ${prebuilt_system_path}"
  nixos-install \
    --option accept-flake-config true \
    --option experimental-features "nix-command flakes" \
    --root "$install_root_mount_point" \
    --system "$prebuilt_system_path" \
    --no-root-passwd \
    --no-bootloader \
    --verbose
  zfs::obs:mark "nixos-install-prebuilt:done"
}

zfs::nixos:install() {
  local nixos_config_name="@nixosConfigName@"
  local ndh_top_level_mount_point="@ndhTopLevelMountPoint@"
  local install_root_mount_point="@installRootMountPoint@"
  local prebuilt_system_path="${NDH_NIXOS_INSTALL_SYSTEM_PATH:-}"
  local copy_from_store="${NDH_NIXOS_INSTALL_COPY_FROM:-}"
  local flake_root=""

  zfs::obs:start
  trap 'zfs::obs:stop' EXIT

  zfs::guard:mountpoint:check "$install_root_mount_point"
  zfs::obs:mark "boot-sync-bringup-to-target:start"
  zfs::boot:sync:bringup:to:target "$install_root_mount_point"
  zfs::obs:mark "boot-sync-bringup-to-target:done"

  if [[ -n "$prebuilt_system_path" ]]; then
    zfs::nixos:install:prebuilt:run "$install_root_mount_point" "$prebuilt_system_path" "$copy_from_store"
  else
    flake_root="$(zfs::flake:root:require "$ndh_top_level_mount_point")"

    zfs::nixos:install:run "$install_root_mount_point" "$flake_root" "$nixos_config_name"
  fi

  zfs::obs:mark "boot-sync-target-to-bringup:start"
  zfs::boot:sync:target:to:bringup "$install_root_mount_point"
  zfs::obs:mark "boot-sync-target-to-bringup:done"
  : "[zfs-nixos-install] installation complete; reboot is intentionally disabled"
}

ndh::logger:command:run "nixos.systemd.zfs-nixos-install" zfs::nixos:install "$@"
