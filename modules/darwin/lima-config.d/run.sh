#!/usr/bin/env bash
# Host-side Lima wrapper with remote NixOS activation support (@codebase)
set -euo pipefail

# shellcheck source=/dev/null
source "@nixBashTrampoline@"

LIMA_HOME="${LIMA_HOME:-${HOME}/.lima}"

LIMA_VM="${LIMA_VM:-nerd-nixos}"
NDH_VZ_HOST="${NDH_VZ_HOST:-@effectiveHostName@}"
NIXOS_FLAKE_PATH="${NIXOS_FLAKE_PATH:-@nixosFlakePath@}"
NIXOS_HOST_ATTR="${NIXOS_HOST_ATTR:-@nixosHostAttr@}"
NIXOS_REMOTE_HOST="${NIXOS_REMOTE_HOST:-root}"
LIMA_VERBOSE="${LIMA_VERBOSE:-0}"
LIMA_QUIET_BUILD="${LIMA_QUIET_BUILD:-0}"
LIMA_EXTERNAL_DISK_SIZE="${LIMA_EXTERNAL_DISK_SIZE:-3G}"
DEFAULT_LIMA_NIXOS_DISK_IMAGE_ATTR="${DEFAULT_LIMA_NIXOS_DISK_IMAGE_ATTR:-nixosDiskImages.@effectiveHostName@.bringup.zfsSystemd}"
LIMA_NIXOS_DISK_IMAGE_ATTR="${LIMA_NIXOS_DISK_IMAGE_ATTR:-}"
NDH_VZ_HOST_FLAKE_REF="${NDH_VZ_HOST_FLAKE_REF:-}"
RESOLVED_NDH_VZ_HOST_FLAKE_REF=""
RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR=""
RESOLVED_DISK_IMAGE_STORE_PATH=""

# Allow overriding the flake reference fully while keeping canonical defaults.
NIXOS_FLAKE_REF="${NIXOS_FLAKE_REF:-${NIXOS_FLAKE_PATH}#${NIXOS_HOST_ATTR}}"
NIXOS_BRINGUP_ROOT_FS="${NIXOS_BRINGUP_ROOT_FS:-btrfs}"
NIXOS_EXT4_FLAKE_REF="${NIXOS_EXT4_FLAKE_REF:-}"
NIXOS_ZFS_FLAKE_REF="${NIXOS_ZFS_FLAKE_REF:-}"
NDH_NIX_CLI_ARGS="${NDH_NIX_CLI_ARGS:--L -v -v}"

nixos:flake:refs:resolve() {
  local flake_base="${NIXOS_FLAKE_REF%%#*}"
  local host_attr="${NIXOS_HOST_ATTR}"
  local host_name

  if [[ "${host_attr}" == *-nixos ]]; then
    host_name="${host_attr%-nixos}"
  else
    host_name="${host_attr}"
  fi

  if [[ -z "${NIXOS_EXT4_FLAKE_REF}" ]]; then
    NIXOS_EXT4_FLAKE_REF="${flake_base}#${host_name}-nixos-lima-bringup-systemd-${NIXOS_BRINGUP_ROOT_FS}"
  fi

  if [[ -z "${NIXOS_ZFS_FLAKE_REF}" ]]; then
    NIXOS_ZFS_FLAKE_REF="${flake_base}#${host_name}-nixos-tart-bringup-systemd-zfs"
  fi
}

host:flake:ref:resolve() {
  local host_flake_ref="${NDH_VZ_HOST_FLAKE_REF}"
  local git_root
  local remotes
  local legacy_root=""

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

    host_flake_ref="${git_root}"
  fi

  if [[ "${host_flake_ref}" == *"#"* ]]; then
    echo "[lima-run][ERROR] NDH_VZ_HOST_FLAKE_REF must be a flake path (no #attr): ${host_flake_ref}" >&2
    exit 2
  fi

  if [[ ! -f "${host_flake_ref}/flake.nix" && "${host_flake_ref}" == */hosts/* ]]; then
    legacy_root="${host_flake_ref%/hosts/*}"
    if [[ -f "${legacy_root}/flake.nix" ]]; then
      host_flake_ref="${legacy_root}"
    fi
  fi

  RESOLVED_NDH_VZ_HOST_FLAKE_REF="${host_flake_ref}"

  if [[ ! -f "${RESOLVED_NDH_VZ_HOST_FLAKE_REF}/flake.nix" ]]; then
    echo "[lima-run][ERROR] expected flake not found: ${RESOLVED_NDH_VZ_HOST_FLAKE_REF}/flake.nix" >&2
    exit 2
  fi
}

lima:disk:image:attr:resolve() {
  if [[ -n "${LIMA_NIXOS_DISK_IMAGE_ATTR}" ]]; then
    RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR="${LIMA_NIXOS_DISK_IMAGE_ATTR}"
    return
  fi

  : "[lima-run] using default disk image attr: ${DEFAULT_LIMA_NIXOS_DISK_IMAGE_ATTR}"
  RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR="${DEFAULT_LIMA_NIXOS_DISK_IMAGE_ATTR}"
}

# shellcheck disable=SC2034
declare -a NERD_NIXOS_DISKS=(tank1 tank2 tank3 recover)
# shellcheck disable=SC2034
declare -a NERD_DEBIAN_DISKS=(tank2 tank3)
# shellcheck disable=SC2034
declare -a NERD_DISKS=(tank2 tank3)

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

  printf '%s\n' "${!disks_var_name}"
}

vm:disk:foreach() {
  local action="$1"
  local -a disks=()
  mapfile -t disks < <(vm:disks:list)

  for disk in "${disks[@]}"; do
    "$action" "$disk"
  done
}

vm:disk:create:all() {
  vm:disk:foreach vm:disk:create
}

vm:disk:unlock:all() {
  vm:disk:foreach vm:disk:unlock
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
    vm:disk:create:all
    return
  fi

  local name="${LIMA_VM}-${1}"
  local disk="${LIMA_HOME}/_disks/${name}"

  [[ -d ${disk} ]] && rm -fr "${disk}"
  limactl disk create "${name}" --format=raw --size 100G
}

vm:disk:unlock() {
  if [[ ${#} -eq 0 ]]; then
    vm:disk:unlock:all
    return
  fi

  local name="${LIMA_VM}-${1}"
  limactl disk unlock "${name}"
}

vm:kill() {
  limactl stop -f "${LIMA_VM}" || true
}

vm:external:disks:should:reset() {
  # Canonical policy: nerd-nixos external disks carry ZFS pool members from the
  # current bringup artifact set; do not recreate them during factory reset.
  [[ "${LIMA_VM}" != "nerd-nixos" ]]
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
  if vm:external:disks:should:reset; then
    vm:disk:create:all
  else
    : "[lima-run] preserving external disks for ${LIMA_VM} (tank2/tank3/recover)"
  fi
  vm:start
}

vm:reset() {
  vm:kill
  host:disk:image:build
  host:lima:tank:disks:import
  host:lima:config:ensure
  vm:factory:reset
}

socket:run() {
  vm:disk:unlock:all
  cat <<! | cut -c 3- | sudo bash -xe -o pipefail
mkdir -p ${rundir:=/private/var/run/lima}
/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet --vmnet-mode=bridged --vmnet-interface=en0 ${rundir}/socket_vmnet.bridged
!
}

vm:ssh:option() {
  local key="$1"
  limactl show-ssh --format=options "${LIMA_VM}" | awk -F= -v key="$key" '$1 == key { gsub(/^"|"$/, "", $2); print $2; exit }'
}

vm:is:running() {
  local status
  status="$(limactl ls --format '{{.Status}}' "${LIMA_VM}" 2>/dev/null || true)"
  [[ "${status}" == "Running" ]]
}

vm:ssh:ensure-started() {
  if ! vm:is:running; then
    vm:start
  fi
}

host:disk:image:build() {
  local -a nix_build_args
  local -a ndh_nix_cli_args=()

  if [[ -n "${NDH_NIX_CLI_ARGS}" ]]; then
    read -r -a ndh_nix_cli_args <<< "${NDH_NIX_CLI_ARGS}"
  fi

  nix_build_args=(build --no-link --print-out-paths "${RESOLVED_NDH_VZ_HOST_FLAKE_REF}#${RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR}")
  if [[ "${LIMA_QUIET_BUILD}" == "1" ]]; then
    nix_build_args=(--quiet "${nix_build_args[@]}")
  fi

  : "[lima-run] building disk image from ${RESOLVED_NDH_VZ_HOST_FLAKE_REF}#${RESOLVED_LIMA_NIXOS_DISK_IMAGE_ATTR}"
  RESOLVED_DISK_IMAGE_STORE_PATH="$(nix "${ndh_nix_cli_args[@]}" "${nix_build_args[@]}")"
}

host:lima:tank:disks:import() {
  [[ -n "${RESOLVED_DISK_IMAGE_STORE_PATH}" ]] || {
    : "[lima-run] no resolved disk image store path; skipping tank disk import"
    return 0
  }

  if vm:is:running; then
    echo "[lima-run][WARN] VM ${LIMA_VM} is still running; skipping tank disk import" >&2
    return 0
  fi

  for disk in tank1 tank2 tank3 recover; do
    local img="${RESOLVED_DISK_IMAGE_STORE_PATH}/${disk}.img"
    [[ -f "${img}" ]] || { : "[lima-run] ${disk}.img not in store path; skipping"; continue; }

    local disk_name="nerd-nixos-${disk}"
    local datadisk="${LIMA_HOME}/_disks/${disk_name}/datadisk"

    if [[ -f "${datadisk}" ]]; then
      # Overwrite existing disk image directly — limactl lock/unlock is unreliable
      # when the instance directory exists (even if VM is stopped).
      echo "[lima-run] overwriting ${disk_name} datadisk from store (seed: $(du -sh "${img}" | cut -f1), target: ${LIMA_EXTERNAL_DISK_SIZE})"
      cp "${img}" "${datadisk}"
      truncate -s "${LIMA_EXTERNAL_DISK_SIZE}" "${datadisk}"
    else
      # Disk not yet registered with limactl — import then extend.
      if limactl disk import "${disk_name}" "${img}" 2>/dev/null; then
        echo "[lima-run] imported ${disk_name} from store"
        truncate -s "${LIMA_EXTERNAL_DISK_SIZE}" "${LIMA_HOME}/_disks/${disk_name}/datadisk"
      else
        echo "[lima-run][WARN] failed to import ${disk_name} from store" >&2
      fi
    fi
  done
}

host:lima:config:ensure() {
  local lima_yaml="${LIMA_HOME}/${LIMA_VM}/lima.yaml"

  if [[ ! -f "${lima_yaml}" ]]; then
    echo "[lima-run][ERROR] missing ${lima_yaml}. Run Lima materializer activation first." >&2
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
  cat <<'EOF'
[lima-run] boot:zfs completed (boot generation updated only).
[lima-run] runtime switch is operator-driven:
  1) run.sh vm:nixos:switch
  2) run.sh vm:nixos:zfs-bootstrap
EOF
}

cli:usage:print() {
  cat <<EOF
Usage: $0 <command>

Optional global arguments (before <command>):
  --flake-uri <flake#attr>         Override NIXOS_FLAKE_REF for this invocation
  --host-flake-uri <flake-path>    Override nix-darwin-home flake path for this invocation
  --disk-image-attr <attr>         Override disk image attribute for this invocation
  --vm <instance>                  Override LIMA_VM for this invocation
  --remote-user <user>             Override NIXOS_REMOTE_HOST for this invocation

Commands:
  vm:disk:nixos:build       Build disk image + ensure Lima config + boot VM
  vm:nixos:boot:ext4        Remote nixos-rebuild boot for ext4/bootstrap target
  vm:nixos:boot:zfs         Remote nixos-rebuild boot for zfs target (operator runs switch/bootstrap later)
  vm:start                  Start Lima VM
  vm:kill                   Terminate limactl process and clear stale lock/pid files
  vm:reset                  Stop VM + build image + import tank disks + check lima config + factory-reset + start
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
  LIMA_QUIET_BUILD=1                (optional: force quiet nix build output)
  LIMA_EXTERNAL_DISK_SIZE=<size>    (default: 3G; per-disk size for tank1/tank2/tank3/recover after seeding from store — 3G × 3 disks gives ~6G usable in raidz1)
  NDH_NIX_CLI_ARGS='-L -v -v'       (optional: global extra nix CLI args for managed nix calls)
  NDH_VZ_HOST=<host>                (default: @effectiveHostName@)
  NDH_VZ_HOST_FLAKE_REF=<flake-path>  (required for vm:disk:nixos:build and vm:reset when not run from a nix-darwin-home checkout)
  DEFAULT_LIMA_NIXOS_DISK_IMAGE_ATTR=<attr> (default: nixosDiskImages.<host>.bringup.zfsSystemd)
  LIMA_NIXOS_DISK_IMAGE_ATTR=<attr> (optional explicit attr override for this invocation)
  NIXOS_FLAKE_PATH=<path>           (default: @nixosFlakePath@)
  NIXOS_HOST_ATTR=<attr>            (default: @nixosHostAttr@)
  NIXOS_FLAKE_REF=<flake#attr>      (overrides path+attr composition)
  NIXOS_EXT4_FLAKE_REF=<flake#attr> (default: <NIXOS_FLAKE_REF base>#<NIXOS_HOST_ATTR%-nixos>-nixos-lima-bringup-systemd-
                                     \\${NIXOS_BRINGUP_ROOT_FS}, default btrfs)
  NIXOS_ZFS_FLAKE_REF=<flake#attr>  (default: <NIXOS_FLAKE_REF base>#<NIXOS_HOST_ATTR%-nixos>-nixos-tart-bringup-systemd-zfs)
  NIXOS_BRINGUP_ROOT_FS=<fs>        (default: btrfs)
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
    vm:start|vm:kill|vm:reset|socket:run)
      "${cmd}" "$@"
      ;;
    vm:disk:create)
      vm:disk:create "$@"
      ;;
    vm:disk:unlock)
      vm:disk:unlock "$@"
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
