#!/usr/bin/env bash
# Host-side Lima wrapper with remote NixOS activation support (@codebase)
set -euo pipefail

# shellcheck disable=SC1091
source "@bashTrampoline@"
# shellcheck disable=SC1091
source "@logger@"

LIMA_HOME="${LIMA_HOME:-${HOME}/.lima}"

LIMA_VM="${LIMA_VM:-nerd-nixos}"
NDH_VZ_HOST="${NDH_VZ_HOST:-@effectiveHostName@}"
NIXOS_FLAKE_PATH="${NIXOS_FLAKE_PATH:-@nixosFlakePath@}"
NIXOS_HOST_ATTR="${NIXOS_HOST_ATTR:-@nixosHostAttr@}"
NIXOS_REMOTE_HOST="${NIXOS_REMOTE_HOST:-root}"
LIMA_VERBOSE="${LIMA_VERBOSE:-0}"
LIMA_QUIET_BUILD="${LIMA_QUIET_BUILD:-1}"
DEFAULT_LIMA_NIXOS_DISK_IMAGE_ATTR="${DEFAULT_LIMA_NIXOS_DISK_IMAGE_ATTR:-nixosDiskImageBringupSystemdBoot}"
LIMA_NIXOS_DISK_IMAGE_ATTR="${LIMA_NIXOS_DISK_IMAGE_ATTR:-}"
NDH_VZ_HOST_FLAKE_REF="${NDH_VZ_HOST_FLAKE_REF:-}"
RESOLVED_NDH_VZ_HOST_FLAKE_REF=""
RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR=""

# Allow overriding the flake reference fully while keeping canonical defaults.
NIXOS_FLAKE_REF="${NIXOS_FLAKE_REF:-${NIXOS_FLAKE_PATH}#${NIXOS_HOST_ATTR}}"
NIXOS_EXT4_FLAKE_REF="${NIXOS_EXT4_FLAKE_REF:-}"
NIXOS_ZFS_FLAKE_REF="${NIXOS_ZFS_FLAKE_REF:-}"
NDH_NIX_CLI_ARGS="${NDH_NIX_CLI_ARGS:--L -v -v}"

nixos:flake:refs:resolve() {
  local flake_base="${NIXOS_FLAKE_REF%%#*}"

  if [[ -z "${NIXOS_EXT4_FLAKE_REF}" ]]; then
    NIXOS_EXT4_FLAKE_REF="${flake_base}#ext4Bringup"
  fi

  if [[ -z "${NIXOS_ZFS_FLAKE_REF}" ]]; then
    NIXOS_ZFS_FLAKE_REF="${flake_base}#zfsBringup"
  fi
}

host:flake:ref:resolve() {
  local host_flake_ref="${NDH_VZ_HOST_FLAKE_REF}"
  local git_root
  local remotes

  if [[ -z "${host_flake_ref}" ]]; then
    git_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "${git_root}" ]]; then
      echo "[lima-run][ERROR] run this command from a nix-darwin-home git worktree, or pass --host-flake-uri explicitly" >&2
      exit 2
    fi

    remotes="$(git -C "$git_root" remote -v 2>/dev/null | awk '{print $2}' | sort -u || true)"
    if ! grep -Eq '(github\.com[:/]nxmatic/nix-darwin-home(\.git)?|^github:nxmatic/nix-darwin-home(\.git)?)' <<<"${remotes}"; then
      echo "[lima-run][ERROR] current worktree is not nxmatic/nix-darwin-home: $git_root" >&2
      exit 2
    fi

    host_flake_ref="${git_root}/hosts/${NDH_VZ_HOST}"
  fi

  if [[ "${host_flake_ref}" == *"#"* ]]; then
    echo "[lima-run][ERROR] NDH_VZ_HOST_FLAKE_REF must be a host flake path (no #attr): ${host_flake_ref}" >&2
    exit 2
  fi

  if [[ "${host_flake_ref}" != */hosts/* ]]; then
    host_flake_ref="${host_flake_ref%/}/hosts/${NDH_VZ_HOST}"
  fi

  RESOLVED_NDH_VZ_HOST_FLAKE_REF="${host_flake_ref}"

  if [[ ! -f "${RESOLVED_NDH_VZ_HOST_FLAKE_REF}/flake.nix" ]]; then
    echo "[lima-run][ERROR] expected host flake not found: ${RESOLVED_NDH_VZ_HOST_FLAKE_REF}/flake.nix" >&2
    exit 2
  fi
}

host:disk:image:symlink:path() {
  echo "${RESOLVED_NDH_VZ_HOST_FLAKE_REF}/outputs.d/nixos-disk-image"
}

host:disk:image:attr:symlink:path() {
  local attr="${1}"
  echo "${RESOLVED_NDH_VZ_HOST_FLAKE_REF}/outputs.d/nixos-disk-image.${attr}"
}

lima:disk:image:descriptor:path() {
  local out_link

  out_link="$(host:disk:image:symlink:path)"
  [[ -e "${out_link}/descriptor.yaml" ]] || return 1
  echo "${out_link}/descriptor.yaml"
}

lima:disk:image:attr:from:descriptor:resolve() {
  local descriptor_path descriptor_attr

  descriptor_path="$(lima:disk:image:descriptor:path)" || return 1
  descriptor_attr="$(awk -F': *' '$1 == "attr" {print $2; exit}' "${descriptor_path}" | tr -d '"[:space:]')"
  [[ -n "${descriptor_attr}" ]] || return 1

  RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR="${descriptor_attr}"
  : "[lima-run] inferred disk image attr from descriptor: ${RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR}"
  return 0
}

lima:disk:image:attr:resolve() {
  if [[ -n "${LIMA_NIXOS_DISK_IMAGE_ATTR}" ]]; then
    RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR="${LIMA_NIXOS_DISK_IMAGE_ATTR}"
    return
  fi

  if lima:disk:image:attr:from:descriptor:resolve; then
    return
  fi

  echo "[lima-run][ERROR] required metadata descriptor missing or invalid: $(host:disk:image:symlink:path)/descriptor.yaml" >&2
  echo "[lima-run][ERROR] build a disk image with metadata first (or pass --disk-image-attr explicitly)." >&2
  exit 2
}

declare -a NERD_NIXOS_DISKS=(tank1 tank2 tank3 recover)
declare -a NERD_DEBIAN_DISKS=(tank1 tank2 tank3 recover)
declare -a NERD_DISKS=(tank1 tank2 tank3 recover)

vm:disks:list() {
  local disks_var_name="NERD_DISKS[@]"

  case "${LIMA_VM}" in
    nerd-nixos)
      disks_var_name="NERD_NIXOS_DISKS[@]"
      ;;
    nerd-debian)
      disks_var_name="NERD_DEBIAN_DISKS[@]"
      ;;
  esac

  echo "${!disks_var_name}"
}

vm:disk:foreach() {
  local action="$1"
  local disks=($(vm:disks:list))

  for disk in "${disks[@]}"; do
    "$action" "$disk"
  done
}

vm:disk:delete() {
  if [[ ${#} -eq 0 ]]; then
    vm:disk:foreach vm:disk:delete
    return
  fi

  local name="${LIMA_VM}-${1}"
  local disk="${LIMA_HOME}/_disks/${name}"

  [[ -d ${disk} ]] && rm -fr "${disk}"
  limactl disk delete "${name}" --format=raw --size 100G
}

vm:disk:create() {
  if [[ ${#} -eq 0 ]]; then
    vm:disk:foreach vm:disk:create
    return
  fi

  local name="${LIMA_VM}-${1}"
  local disk="${LIMA_HOME}/_disks/${name}"

  [[ -d ${disk} ]] && rm -fr "${disk}"
  limactl disk create "${name}" --format=raw --size 100G
}

vm:disk:unlock() {
  if [[ ${#} -eq 0 ]]; then
    vm:disk:foreach vm:disk:unlock
    return
  fi

  local name="${LIMA_VM}-${1}"
  limactl disk unlock "${name}"
}

vm:kill() {
  limactl stop -f "${LIMA_VM}" || true
}

vm:config:mode() {
  local mode="${1:-headless}"
  local instance_dir="${LIMA_HOME}/${LIMA_VM}"
  local active_yaml="${instance_dir}/lima.yaml"
  local headless_yaml="${instance_dir}/lima.headless.yaml"
  local gui_yaml="${instance_dir}/lima.gui.yaml"
  local active_target

  case "${mode}" in
    headless)
      [[ -e "${headless_yaml}" ]] || { echo "[lima-run][ERROR] missing ${headless_yaml}" >&2; exit 1; }
      ln -sfn "${headless_yaml}" "${active_yaml}"
      ;;
    gui|graphic|graphics)
      [[ -e "${gui_yaml}" ]] || { echo "[lima-run][ERROR] missing ${gui_yaml}" >&2; exit 1; }
      ln -sfn "${gui_yaml}" "${active_yaml}"
      ;;
    *)
      echo "[lima-run][ERROR] unknown mode: ${mode} (expected: headless|gui)" >&2
      exit 2
      ;;
  esac

  active_target="$(readlink "${active_yaml}" 2>/dev/null || true)"
  if [[ -z "${active_target}" ]]; then
    active_target="${active_yaml}"
  fi
  : "[lima-run] active config -> ${active_target}"
}

vm:start:gui() {
  vm:config:mode gui
  vm:start
}

vm:start:headless() {
  vm:config:mode headless
  vm:start
}

vm:start() {
  truncate -s 0 "${LIMA_HOME}/${LIMA_VM}"/*.log 2>/dev/null || true
  limactl start "${LIMA_VM}"
  if command -v birdc >/dev/null 2>&1; then
    sudo birdc restart device
  fi
}

vm:factory:reset() {
  limactl factory-reset "${LIMA_VM}"
  vm:disk:create
  vm:start
}

vm:reset() {
  host:disk:image:build
  host:lima:config:ensure
  vm:factory:reset
}

socket:run() {
  vm:disk:unlock
  cat <<! | cut -c 3- | sudo bash -xe -o pipefail
mkdir -p ${rundir:=/private/var/run/lima}
/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet --vmnet-mode=bridged --vmnet-interface=en0 ${rundir}/socket_vmnet.bridged
!
}

vm:ssh:option() {
  local key="$1"
  limactl show-ssh --format=options "${LIMA_VM}" | awk -F= -v key="$key" '$1 == key { gsub(/^"|"$/, "", $2); print $2; exit }'
}

vm:ssh:ensure-started() {
  local status
  status="$(limactl ls --format '{{.Status}}' "${LIMA_VM}" 2>/dev/null || true)"
  if [[ "${status}" != "Running" ]]; then
    vm:start
  fi
}

host:disk:image:build() {
  local out_link="${RESOLVED_NDH_VZ_HOST_FLAKE_REF}/outputs.d/nixos-disk-image"
  local attr_out_link
  local -a nix_build_args
  local -a ndh_nix_cli_args=()

  if [[ -n "${NDH_NIX_CLI_ARGS}" ]]; then
    read -r -a ndh_nix_cli_args <<< "${NDH_NIX_CLI_ARGS}"
  fi

  mkdir -p "${RESOLVED_NDH_VZ_HOST_FLAKE_REF}"
  attr_out_link="$(host:disk:image:attr:symlink:path "${RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR}")"
  : "[lima-run] building disk image from ${RESOLVED_NDH_VZ_HOST_FLAKE_REF}#${RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR}"
  nix_build_args=(build --out-link "${attr_out_link}" "${RESOLVED_NDH_VZ_HOST_FLAKE_REF}#${RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR}")
  if [[ "${LIMA_QUIET_BUILD}" == "1" ]]; then
    nix_build_args=(--quiet "${nix_build_args[@]}")
  fi
  nix "${ndh_nix_cli_args[@]}" "${nix_build_args[@]}"

  ln -sfn "$(basename "${attr_out_link}")" "${out_link}"
}

host:lima:config:ensure() {
  local lima_yaml="${LIMA_HOME}/${LIMA_VM}/lima.yaml"
  local -a ndh_nix_cli_args=()

  if [[ -n "${NDH_NIX_CLI_ARGS}" ]]; then
    read -r -a ndh_nix_cli_args <<< "${NDH_NIX_CLI_ARGS}"
  fi

  if [[ "${LIMA_REFRESH_CONFIG:-0}" == "1" ]]; then
    : "[lima-run] refreshing Lima config via darwin activation"
    if command -v darwin-rebuild >/dev/null 2>&1; then
      darwin-rebuild switch --flake "${RESOLVED_NDH_VZ_HOST_FLAKE_REF}"
    else
      nix "${ndh_nix_cli_args[@]}" run nix-darwin -- switch --flake "${RESOLVED_NDH_VZ_HOST_FLAKE_REF}"
    fi
  fi

  if [[ ! -f "${lima_yaml}" ]]; then
    echo "[lima-run][ERROR] missing ${lima_yaml}. Run darwin activation or set LIMA_REFRESH_CONFIG=1." >&2
    exit 1
  fi
}

vm:nixos:rebuild() {
  local action="${1:-switch}"
  local flake_ref="${2:-${NIXOS_FLAKE_REF}}"
  local -a ndh_nix_cli_args=()

  if [[ -n "${NDH_NIX_CLI_ARGS}" ]]; then
    read -r -a ndh_nix_cli_args <<< "${NDH_NIX_CLI_ARGS}"
  fi

  vm:ssh:ensure-started

  local host port identity
  host="$(vm:ssh:option Hostname)"
  port="$(vm:ssh:option Port)"
  identity="$(vm:ssh:option IdentityFile)"

  if [[ -z "${host}" || -z "${port}" || -z "${identity}" ]]; then
    echo "[lima-run][ERROR] failed to resolve SSH options for VM ${LIMA_VM}" >&2
    exit 1
  fi

  local ssh_opts
  ssh_opts="-o Port=${port} -o IdentityFile=${identity} -o StrictHostKeyChecking=accept-new"

  : "[lima-run] nixos-rebuild ${action} --flake ${flake_ref} --build-host ${NIXOS_REMOTE_HOST}@${host} --target-host ${NIXOS_REMOTE_HOST}@${host}"

  if command -v nixos-rebuild >/dev/null 2>&1; then
    NIX_SSHOPTS="${ssh_opts}" nixos-rebuild "${action}" \
      --flake "${flake_ref}" \
      --build-host "${NIXOS_REMOTE_HOST}@${host}" \
      --target-host "${NIXOS_REMOTE_HOST}@${host}" \
      --use-remote-sudo
  else
    NIX_SSHOPTS="${ssh_opts}" nix "${ndh_nix_cli_args[@]}" run nixpkgs#nixos-rebuild -- "${action}" \
      --flake "${flake_ref}" \
      --build-host "${NIXOS_REMOTE_HOST}@${host}" \
      --target-host "${NIXOS_REMOTE_HOST}@${host}" \
      --use-remote-sudo
  fi
}

vm:nixos:zfs-bootstrap() {
  vm:ssh:ensure-started
  : "[lima-run] starting zfs-bootstrap-activation.service on ${LIMA_VM}"
  limactl shell "${LIMA_VM}" sudo systemctl start zfs-bootstrap-activation.service
  if [[ "${LIMA_VERBOSE}" == "1" ]]; then
    limactl shell "${LIMA_VM}" sudo systemctl --no-pager --full status zfs-bootstrap-activation.service || true
  fi
}

vm:disk:nixos:build() {
  vm:reset
}

vm:nixos:boot:ext4() {
  vm:nixos:rebuild boot "${NIXOS_EXT4_FLAKE_REF}"
}

vm:nixos:boot:zfs() {
  vm:nixos:rebuild boot "${NIXOS_ZFS_FLAKE_REF}"
  vm:nixos:rebuild switch "${NIXOS_ZFS_FLAKE_REF}"
  vm:nixos:zfs-bootstrap
}

cli:usage:print() {
  cat <<EOF
Usage: $0 <command>

Optional global arguments (before <command>):
  --flake-uri <flake#attr>         Override NIXOS_FLAKE_REF for this invocation
  --host-flake-uri <flake-path>    Override host flake path for this invocation
  --disk-image-attr <attr>         Override disk image attribute for this invocation
  --vm <instance>                  Override LIMA_VM for this invocation
  --remote-user <user>             Override NIXOS_REMOTE_HOST for this invocation

Commands:
  vm:disk:nixos:build       Build disk image + ensure Lima config + boot VM
  vm:nixos:boot:ext4        Remote nixos-rebuild boot for ext4/bootstrap target
  vm:nixos:boot:zfs         Remote nixos-rebuild boot+switch for zfs target + zfs bootstrap unit
  vm:start                  Start Lima VM
  vm:start:gui              Switch active config to GUI and start Lima VM
  vm:start:headless         Switch active config to headless and start Lima VM
  vm:config:mode <mode>     Set active config symlink (headless|gui)
  vm:kill                   Terminate limactl process and clear stale lock/pid files
  vm:reset                  Build image + ensure Lima config + factory-reset VM + start
  vm:disk:create [name]     Create one/all additional disks
  vm:disk:unlock [name]     Unlock one/all additional disks
  socket:run                Start socket_vmnet bridge helper
  vm:nixos:switch           Remote NixOS switch using nixos-rebuild --build-host/--target-host
  vm:nixos:boot             Remote NixOS boot using nixos-rebuild --build-host/--target-host
  vm:nixos:zfs-bootstrap    Start idempotent zfs bootstrap activation unit remotely

Environment overrides:
  LIMA_HOME=<path>                  (default: ${HOME}/.lima)
  LIMA_VM=<instance>                (default: nerd-nixos)
  LIMA_VERBOSE=1                    (optional: enable extra runtime status output)
  LIMA_QUIET_BUILD=0                (optional: disable quiet nix build output)
  NDH_NIX_CLI_ARGS='-L -v -v'       (optional: global extra nix CLI args for managed nix calls)
  NDH_VZ_HOST=<host>                (default: @effectiveHostName@)
  NDH_VZ_HOST_FLAKE_REF=<flake-path>  (required for vm:disk:nixos:build and vm:reset when not run from a nix-darwin-home checkout)
  DEFAULT_LIMA_NIXOS_DISK_IMAGE_ATTR=<attr> (default: nixosDiskImageBringupSystemdBoot)
  LIMA_NIXOS_DISK_IMAGE_ATTR=<attr> (optional explicit attr override for this invocation)
  LIMA_REFRESH_CONFIG=1             (optional: run darwin switch to refresh lima config first)
  NIXOS_FLAKE_PATH=<path>           (default: @nixosFlakePath@)
  NIXOS_HOST_ATTR=<attr>            (default: @nixosHostAttr@)
  NIXOS_FLAKE_REF=<flake#attr>      (overrides path+attr composition)
  NIXOS_EXT4_FLAKE_REF=<flake#attr> (default: <NIXOS_FLAKE_REF base>#ext4Bringup)
  NIXOS_ZFS_FLAKE_REF=<flake#attr>  (default: <NIXOS_FLAKE_REF base>#zfsBringup)
  NIXOS_REMOTE_HOST=<user>          (default: root)
EOF
}

cli:main:run() {
  local cmd_requires_host_flake=0
  local cmd_requires_disk_attr=0

  while [[ ${#} -gt 0 ]]; do
    case "${1}" in
      --flake-uri)
        shift
        [[ ${#} -gt 0 ]] || { echo "missing value for --flake-uri" >&2; exit 2; }
        NIXOS_FLAKE_REF="${1}"
        ;;
      --host-flake-uri)
        shift
        [[ ${#} -gt 0 ]] || { echo "missing value for --host-flake-uri" >&2; exit 2; }
        NDH_VZ_HOST_FLAKE_REF="${1}"
        ;;
      --disk-image-attr)
        shift
        [[ ${#} -gt 0 ]] || { echo "missing value for --disk-image-attr" >&2; exit 2; }
        LIMA_NIXOS_DISK_IMAGE_ATTR="${1}"
        ;;
      --vm)
        shift
        [[ ${#} -gt 0 ]] || { echo "missing value for --vm" >&2; exit 2; }
        LIMA_VM="${1}"
        ;;
      --remote-user)
        shift
        [[ ${#} -gt 0 ]] || { echo "missing value for --remote-user" >&2; exit 2; }
        NIXOS_REMOTE_HOST="${1}"
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Unknown option: ${1}" >&2
        exit 2
        ;;
      *)
        break
        ;;
    esac
    shift
  done

  local cmd="${1:-help}"
  shift || true

  case "${cmd}" in
    vm:disk:nixos:build|vm:reset)
      cmd_requires_host_flake=1
      cmd_requires_disk_attr=1
      ;;
  esac

  nixos:flake:refs:resolve

  if [[ "${cmd_requires_host_flake}" == "1" ]]; then
    host:flake:ref:resolve
  fi

  if [[ "${cmd_requires_disk_attr}" == "1" ]]; then
    lima:disk:image:attr:resolve
  fi

  case "${cmd}" in
    vm:disk:nixos:build|vm:nixos:boot:ext4|vm:nixos:boot:zfs)
      "${cmd}" "$@"
      ;;
    vm:start|vm:start:gui|vm:start:headless|vm:kill|vm:reset|socket:run)
      "${cmd}" "$@"
      ;;
    vm:config:mode)
      "${cmd}" "$@"
      ;;
    vm:disk:create|vm:disk:unlock)
      "${cmd}" "$@"
      ;;
    vm:nixos:switch)
      vm:nixos:rebuild switch
      ;;
    vm:nixos:boot)
      vm:nixos:rebuild boot
      ;;
    vm:nixos:zfs-bootstrap)
      vm:nixos:zfs-bootstrap
      ;;
    help|-h|--help)
      cli:usage:print
      ;;
    *)
      echo "Unknown command: ${cmd}" >&2
      cli:usage:print
      exit 2
      ;;
  esac
}

cli:main:run "$@"
