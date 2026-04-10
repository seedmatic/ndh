#!/usr/bin/env bash
# Host-side Lima wrapper with remote NixOS activation support (@codebase)
set -euo pipefail

LIMA_HOME="${LIMA_HOME:-${HOME}/.lima}"

LIMA_VM="${LIMA_VM:-nerd-nixos}"
NDH_ACCESS_HOST="${NDH_ACCESS_HOST:-@effectiveHostName@}"
NIXOS_FLAKE_PATH="${NIXOS_FLAKE_PATH:-@nixosFlakePath@}"
NIXOS_HOST_ATTR="${NIXOS_HOST_ATTR:-@nixosHostAttr@}"
NIXOS_REMOTE_HOST="${NIXOS_REMOTE_HOST:-root}"
LIMA_NIXOS_DISK_IMAGE_ATTR="${LIMA_NIXOS_DISK_IMAGE_ATTR:-nixosDiskImageBringupSystemdBoot}"
NDH_ACCESS_HOST_FLAKE_REF="${NDH_ACCESS_HOST_FLAKE_REF:-}"
RESOLVED_NDH_ACCESS_HOST_FLAKE_REF=""

# Allow overriding the flake reference fully while keeping canonical defaults.
NIXOS_FLAKE_REF="${NIXOS_FLAKE_REF:-${NIXOS_FLAKE_PATH}#${NIXOS_HOST_ATTR}}"
NIXOS_EXT4_FLAKE_REF="${NIXOS_EXT4_FLAKE_REF:-}"
NIXOS_ZFS_FLAKE_REF="${NIXOS_ZFS_FLAKE_REF:-}"

resolve:nixos:flake:refs() {
  local flake_base="${NIXOS_FLAKE_REF%%#*}"

  if [[ -z "${NIXOS_EXT4_FLAKE_REF}" ]]; then
    NIXOS_EXT4_FLAKE_REF="${flake_base}#ext4"
  fi

  if [[ -z "${NIXOS_ZFS_FLAKE_REF}" ]]; then
    NIXOS_ZFS_FLAKE_REF="${flake_base}#zfs"
  fi
}

resolve:host:flake:ref() {
  local host_flake_ref="${NDH_ACCESS_HOST_FLAKE_REF}"
  local git_root
  local remotes

  if [[ -z "${host_flake_ref}" ]]; then
    git_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "${git_root}" ]]; then
      echo "[lima-run][ERROR] run this command from a nix-darwin-home git worktree, or pass --host-flake-uri explicitly" >&2
      exit 2
    fi

    remotes="$(git -C "$git_root" remote -v 2>/dev/null | awk '{print $2}' | sort -u || true)"
    if ! printf '%s\n' "$remotes" | grep -Eq '(github\.com[:/]nxmatic/nix-darwin-home(\.git)?|^github:nxmatic/nix-darwin-home(\.git)?)'; then
      echo "[lima-run][ERROR] current worktree is not nxmatic/nix-darwin-home: $git_root" >&2
      exit 2
    fi

    host_flake_ref="${git_root}/hosts/${NDH_ACCESS_HOST}"
  fi

  if [[ "${host_flake_ref}" == *"#"* ]]; then
    echo "[lima-run][ERROR] NDH_ACCESS_HOST_FLAKE_REF must be a host flake path (no #attr): ${host_flake_ref}" >&2
    exit 2
  fi

  if [[ "${host_flake_ref}" != */hosts/* ]]; then
    host_flake_ref="${host_flake_ref%/}/hosts/${NDH_ACCESS_HOST}"
  fi

  RESOLVED_NDH_ACCESS_HOST_FLAKE_REF="${host_flake_ref}"

  if [[ ! -f "${RESOLVED_NDH_ACCESS_HOST_FLAKE_REF}/flake.nix" ]]; then
    echo "[lima-run][ERROR] expected host flake not found: ${RESOLVED_NDH_ACCESS_HOST_FLAKE_REF}/flake.nix" >&2
    exit 2
  fi
}

declare -a NERD_NIXOS_DISKS=(tank1 tank2 tank3 recover)
declare -a NERD_DEBIAN_DISKS=(tank1 tank2 tank3 recover)
declare -a NERD_DISKS=(tank1 tank2 tank3 recover)

declare -A VM_DISKS
VM_DISKS[nerd-nixos]=NERD_NIXOS_DISKS[@]
VM_DISKS[nerd-debian]=NERD_DEBIAN_DISKS[@]

declare -A VM
VM[name]="${LIMA_VM}"

get_vm_disks() {
  local vm_name="${VM[name]}"
  local disks_var_name="${VM_DISKS[$vm_name]:-NERD_DISKS[@]}"
  echo "${!disks_var_name}"
}

vm:disk:foreach() {
  local action="$1"
  local disks=($(get_vm_disks))

  for disk in "${disks[@]}"; do
    "$action" "$disk"
  done
}

vm:disk:delete() {
  if [[ ${#} -eq 0 ]]; then
    vm:disk:foreach vm:disk:delete
    return
  fi

  local name="${VM[name]}-${1}"
  local disk="${LIMA_HOME}/_disks/${name}"

  [[ -d ${disk} ]] && rm -fr "${disk}"
  limactl disk delete "${name}" --format=raw --size 100G
}

vm:disk:create() {
  if [[ ${#} -eq 0 ]]; then
    vm:disk:foreach vm:disk:create
    return
  fi

  local name="${VM[name]}-${1}"
  local disk="${LIMA_HOME}/_disks/${name}"

  [[ -d ${disk} ]] && rm -fr "${disk}"
  limactl disk create "${name}" --format=raw --size 100G
}

vm:disk:unlock() {
  if [[ ${#} -eq 0 ]]; then
    vm:disk:foreach vm:disk:unlock
    return
  fi

  local name="${VM[name]}-${1}"
  limactl disk unlock "${name}"
}

vm:kill() {
  limactl stop -f "${VM[name]}" || true
}

vm:config:mode() {
  local mode="${1:-headless}"
  local instance_dir="${LIMA_HOME}/${VM[name]}"
  local active_yaml="${instance_dir}/lima.yaml"
  local headless_yaml="${instance_dir}/lima.headless.yaml"
  local gui_yaml="${instance_dir}/lima.gui.yaml"

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

  echo "[lima-run] active config -> $(readlink "${active_yaml}" || echo "${active_yaml}")"
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
  truncate -s 0 "${LIMA_HOME}/${VM[name]}"/*.log 2>/dev/null || true
  limactl start "${VM[name]}"
  if command -v birdc >/dev/null 2>&1; then
    sudo birdc restart device
  fi
}

vm:factory:reset() {
  limactl factory-reset "${VM[name]}"
  vm:disk:create
  vm:start
}

vm:reset() {
  host:disk-image:build
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
  limactl show-ssh --format=options "${VM[name]}" | awk -F= -v key="$key" '$1 == key { gsub(/^"|"$/, "", $2); print $2; exit }'
}

vm:ssh:ensure-started() {
  local status
  status="$(limactl ls --format '{{.Status}}' "${VM[name]}" 2>/dev/null || true)"
  if [[ "${status}" != "Running" ]]; then
    vm:start
  fi
}

host:disk-image:build() {
  local out_link="${RESOLVED_NDH_ACCESS_HOST_FLAKE_REF}/nixos-disk-image"
  mkdir -p "${RESOLVED_NDH_ACCESS_HOST_FLAKE_REF}"
  echo "[lima-run] building disk image from ${RESOLVED_NDH_ACCESS_HOST_FLAKE_REF}#${LIMA_NIXOS_DISK_IMAGE_ATTR}"
  nix build --out-link "${out_link}" "${RESOLVED_NDH_ACCESS_HOST_FLAKE_REF}#${LIMA_NIXOS_DISK_IMAGE_ATTR}"
}

host:lima:config:ensure() {
  local lima_yaml="${LIMA_HOME}/${VM[name]}/lima.yaml"

  if [[ "${LIMA_REFRESH_CONFIG:-0}" == "1" ]]; then
    echo "[lima-run] refreshing Lima config via darwin activation"
    if command -v darwin-rebuild >/dev/null 2>&1; then
      darwin-rebuild switch --flake "${RESOLVED_NDH_ACCESS_HOST_FLAKE_REF}"
    else
      nix run nix-darwin -- switch --flake "${RESOLVED_NDH_ACCESS_HOST_FLAKE_REF}"
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
  vm:ssh:ensure-started

  local host port identity
  host="$(vm:ssh:option Hostname)"
  port="$(vm:ssh:option Port)"
  identity="$(vm:ssh:option IdentityFile)"

  if [[ -z "${host}" || -z "${port}" || -z "${identity}" ]]; then
    echo "[lima-run][ERROR] failed to resolve SSH options for VM ${VM[name]}" >&2
    exit 1
  fi

  local ssh_opts
  ssh_opts="-o Port=${port} -o IdentityFile=${identity} -o StrictHostKeyChecking=accept-new"

  echo "[lima-run] nixos-rebuild ${action} --flake ${flake_ref} --target-host ${NIXOS_REMOTE_HOST}@${host}"

  if command -v nixos-rebuild >/dev/null 2>&1; then
    NIX_SSHOPTS="${ssh_opts}" nixos-rebuild "${action}" \
      --flake "${flake_ref}" \
      --target-host "${NIXOS_REMOTE_HOST}@${host}" \
      --use-remote-sudo
  else
    NIX_SSHOPTS="${ssh_opts}" nix run nixpkgs#nixos-rebuild -- "${action}" \
      --flake "${flake_ref}" \
      --target-host "${NIXOS_REMOTE_HOST}@${host}" \
      --use-remote-sudo
  fi
}

vm:nixos:zfs-bootstrap() {
  vm:ssh:ensure-started
  echo "[lima-run] starting zfs-bootstrap-activation.service on ${VM[name]}"
  limactl shell "${VM[name]}" sudo systemctl start zfs-bootstrap-activation.service
  limactl shell "${VM[name]}" sudo systemctl --no-pager --full status zfs-bootstrap-activation.service || true
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

# Backward-compatibility aliases during transition (@codebase)
vm:nixos:build() {
  vm:disk:nixos:build
}

phase:bootstrap:vm() {
  vm:disk:nixos:build
}

phase:bootstrap:zfs() {
  vm:nixos:boot:zfs
}

phase:bootstrap:all() {
  vm:disk:nixos:build
  vm:nixos:boot:ext4
  vm:nixos:boot:zfs
}

usage() {
  cat <<EOF
Usage: $0 <command>

Optional global arguments (before <command>):
  --flake-uri <flake#attr>         Override NIXOS_FLAKE_REF for this invocation
  --host-flake-uri <flake-path>    Override host flake path for this invocation
  --vm <instance>                  Override LIMA_VM for this invocation
  --remote-user <user>             Override NIXOS_REMOTE_HOST for this invocation

Commands:
  vm:disk:nixos:build       Build disk image + ensure Lima config + boot VM
  vm:nixos:build            Alias of vm:disk:nixos:build
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
  phase:bootstrap:vm        Alias of vm:disk:nixos:build
  phase:bootstrap:zfs       Alias of vm:nixos:boot:zfs
  phase:bootstrap:all       Alias of vm:disk:nixos:build + boot:ext4 + boot:zfs
  vm:nixos:switch           Remote NixOS switch using nixos-rebuild --target-host
  vm:nixos:boot             Remote NixOS boot using nixos-rebuild --target-host
  vm:nixos:zfs-bootstrap    Start idempotent zfs bootstrap activation unit remotely

Environment overrides:
  LIMA_HOME=<path>                  (default: ${HOME}/.lima)
  LIMA_VM=<instance>                (default: nerd-nixos)
  NDH_ACCESS_HOST=<host>            (default: @effectiveHostName@)
  NDH_ACCESS_HOST_FLAKE_REF=<flake-path>  (default: derived from current nxmatic/nix-darwin-home worktree as <worktree>/hosts/${NDH_ACCESS_HOST})
  LIMA_NIXOS_DISK_IMAGE_ATTR=<attr> (default: nixosDiskImageBringupSystemdBoot)
  LIMA_REFRESH_CONFIG=1             (optional: run darwin switch to refresh lima config first)
  NIXOS_FLAKE_PATH=<path>           (default: @nixosFlakePath@)
  NIXOS_HOST_ATTR=<attr>            (default: @nixosHostAttr@)
  NIXOS_FLAKE_REF=<flake#attr>      (overrides path+attr composition)
  NIXOS_EXT4_FLAKE_REF=<flake#attr> (default: <NIXOS_FLAKE_REF base>#ext4)
  NIXOS_ZFS_FLAKE_REF=<flake#attr>  (default: <NIXOS_FLAKE_REF base>#zfs)
  NIXOS_REMOTE_HOST=<user>          (default: root)
EOF
}

main() {
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
        NDH_ACCESS_HOST_FLAKE_REF="${1}"
        ;;
      --vm)
        shift
        [[ ${#} -gt 0 ]] || { echo "missing value for --vm" >&2; exit 2; }
        LIMA_VM="${1}"
        VM[name]="${LIMA_VM}"
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

  resolve:nixos:flake:refs
  resolve:host:flake:ref

  local cmd="${1:-help}"
  shift || true

  case "${cmd}" in
    vm:disk:nixos:build|vm:nixos:build|vm:nixos:boot:ext4|vm:nixos:boot:zfs)
      "${cmd}" "$@"
      ;;
    phase:bootstrap:vm|phase:bootstrap:zfs|phase:bootstrap:all)
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
      usage
      ;;
    *)
      echo "Unknown command: ${cmd}" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
