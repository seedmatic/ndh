#!/usr/bin/env bash

bringup::create_raw_disk() {
  local file="$1"
  local size_mib="$2"
  truncate -s "${size_mib}M" "$file"
}

bringup::link_legacy_block_devices() {
  cp -sv /dev/vda /dev/sda
  cp -sv /dev/vda /dev/xvda
}

bringup::ensure_nixbld_group() {
  if getent group nixbld >/dev/null 2>&1; then
    return 0
  fi

  if command -v groupadd >/dev/null 2>&1; then
    groupadd -r nixbld >/dev/null 2>&1 || true
  fi
}

bringup::ensure_usr_bin_env() {
  [[ -x /usr/bin/env ]] && return 0

  mkdir -p /usr/bin
  ln -sf "$(command -v env)" /usr/bin/env
}

bringup::udev_block_sync() {
  local systemd_udevd_path="${1:-}"

  if [[ -n "$systemd_udevd_path" && -x "$systemd_udevd_path" ]]; then
    "$systemd_udevd_path" --daemon || true
  fi

  udevadm trigger --subsystem-match=block || true
  udevadm settle --timeout 30 || true
}

# Mount the target's /nix/store as overlay(read-only EROFS lower + ZFS upper).
#
# The lower is a whole-disk EROFS image packed on the build host and attached to
# this VM read-only, so the closure is never unpacked file-by-file in here — that
# unpacking is what dominated the build (~260k files at ~11 ms each).  Located by
# filesystem label: which virtio slot it landed in is not ours to pin.
bringup::mount_prebuilt_store() {
  # bringup::mount_prebuilt_store <target_root> <rw_mountpoint> <store_mountpoint> <label:ro_mountpoint>...
  #
  # The layer specs arrive oldest-first, the order erofs-store-layers.nix
  # declares.  They are prepended into `lowerdirs`, so the overlay gets them
  # newest-first: overlayfs searches lowerdir left to right, and a path a later
  # generation re-packs has to win over the copy an earlier layer holds.
  local target_root="$1"
  local rw_mountpoint="$2"
  local store_mountpoint="$3"
  shift 3

  local spec label ro_mountpoint device
  local -a lowerdirs=()

  mkdir -p \
    "${target_root}${rw_mountpoint}/upper" \
    "${target_root}${rw_mountpoint}/work" \
    "${target_root}${store_mountpoint}"

  for spec in "$@"; do
    label="${spec%%:*}"
    ro_mountpoint="${spec#*:}"
    device="/dev/disk/by-label/${label}"

    if [[ ! -b "$device" ]]; then
      echo "[bringup-image][ERROR] prebuilt store layer not found by label: ${device}" >&2
      lsblk -o NAME,SIZE,FSTYPE,LABEL >&2 || true
      return 1
    fi

    mkdir -p "${target_root}${ro_mountpoint}"
    mount -t erofs -o ro "$device" "${target_root}${ro_mountpoint}"
    lowerdirs=("${target_root}${ro_mountpoint}" "${lowerdirs[@]}")
  done

  if ((${#lowerdirs[@]} == 0)); then
    echo "[bringup-image][ERROR] no prebuilt store layer was declared" >&2
    return 1
  fi

  local lowerdir_option
  lowerdir_option="$(
    IFS=:
    printf '%s' "${lowerdirs[*]}"
  )"

  mount -t overlay overlay \
    -o "lowerdir=${lowerdir_option},upperdir=${target_root}${rw_mountpoint}/upper,workdir=${target_root}${rw_mountpoint}/work" \
    "${target_root}${store_mountpoint}"
}

# Reverse of the above.  Must run before disko unmounts the pool: the overlay
# pins the ZFS dataset carrying its upper/work dirs.
bringup::umount_prebuilt_store() {
  # bringup::umount_prebuilt_store <target_root> <store_mountpoint> <ro_mountpoint>...
  #
  # The overlay pins every layer beneath it, so it comes down first; the layers
  # arrive newest-first, the reverse of the mount order.
  local target_root="$1"
  local store_mountpoint="$2"
  shift 2

  local ro_mountpoint

  umount "${target_root}${store_mountpoint}" || true
  for ro_mountpoint in "$@"; do
    umount "${target_root}${ro_mountpoint}" || true
  done
}

# Register the closure as valid in the TARGET's Nix database.
#
# The store files arrive with the image rather than through `nix copy`, so
# nothing else would mark them valid — and an unregistered store makes every
# later `nix copy` (including the one nixos-install performs) decide it has to
# re-write the whole closure into the overlay upper, which is exactly the cost
# this design removes.
bringup::register_target_store_db() {
  local target_root="$1"
  local registration="$2"

  NIX_STATE_DIR="${target_root}/nix/var/nix" \
    nix-store --option build-users-group "" --load-db < "$registration"
}

bringup::assert_toplevel_in_target_store() {
  local target_root="$1"
  local toplevel_path="$2"

  if [[ ! -x "${target_root}${toplevel_path}/init" ]]; then
    echo "[bringup-image][ERROR] prebuilt store missing system closure init: ${target_root}${toplevel_path}/init" >&2
    ls -la "${target_root}$(dirname "$toplevel_path")" >&2 || true
    return 1
  fi
}
