#!/usr/bin/env bash

bringup::bool_is_true() {
  local value="${1:-false}"
  [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" ]]
}

bringup::create_raw_disk() {
  local file="$1"
  local size_mib="$2"
  local use_qemu_img="${3:-false}"

  if bringup::bool_is_true "$use_qemu_img"; then
    create -f raw "$file" "${size_mib}M"
  else
    truncate -s "${size_mib}M" "$file"
  fi
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

bringup::ensure_toplevel_in_target_store() {
  local target_root="$1"
  local toplevel_path="$2"

  nix -L -v -v --extra-experimental-features nix-command --option build-users-group "" \
    copy --no-check-sigs --to "local?root=${target_root}" "$toplevel_path"

  if [[ ! -x "${target_root}${toplevel_path}/init" ]]; then
    echo "[bringup-image][ERROR] copied system closure missing init: ${target_root}${toplevel_path}/init" >&2
    ls -la "${target_root}$(dirname "$toplevel_path")" >&2 || true
    return 1
  fi
}
