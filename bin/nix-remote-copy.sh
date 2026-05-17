#!/usr/bin/env -S bash -euo pipefail

# Usage:
#   ./bin/nix-remote-copy.sh [attr] [mode] [target]
#
# Positional defaults:
#   attr   = homeManagerConfigurations.bringup.activationPackage
#   mode   = copy   (or: print / --print-out-path)
#   target = vz.nikopol
#
# Environment override:
#   NIX_REMOTE_COPY_TARGET
#
# `vz.<host>` targets the bare-metal Mac hosting the nikopol Tart VM.
# Renamed from the historical `vz-host.<host>` for consistency with
# the single-word service-prefix namespace (rdp.<host>, ssh-host.<host>,
# headscale.<host>).  The alias resolves differently depending on
# where this script runs:
#   - On the nikopol VM: ARP-cache lookup of the bare metal's stable
#     hardware MAC, on whatever Wi-Fi the laptop is currently on.
#     See hosts/nikopol/modules/darwin/vz-host-resolver.nix.
#   - On bioskop or any other operator host: ProxyJump=nikopol → the
#     same resolver inside the VM.  See modules/home-manager/
#     ssh-tailnet-hosts.nix's vzAliasForBioskopSide.

host="${NDH_VZ_HOST:-nikopol}"
attr="${1:-homeManagerConfigurations.${host}.bringup.activationPackage}"
mode="${2:-copy}"
target="${3:-${NIX_REMOTE_COPY_TARGET:-vz.${host}}}"

# Normalize legacy generic materializer attrs to host-scoped names.
case "${attr}" in
  apps.aarch64-darwin.nerd-lima-vm-materialize)
    attr="apps.aarch64-darwin.${host}-lima-vm-materialize"
    ;;
  apps.aarch64-darwin.nerd-tart-vm-materialize)
    attr="apps.aarch64-darwin.${host}-tart-vm-materialize"
    ;;
  packages.aarch64-darwin.nerd-lima-vm-materialize)
    attr="packages.aarch64-darwin.${host}-lima-vm-materialize"
    ;;
  packages.aarch64-darwin.nerd-tart-vm-materialize)
    attr="packages.aarch64-darwin.${host}-tart-vm-materialize"
    ;;
esac

build_attr="${attr}"
out=""
resolved_from_app_program=0

if [[ "${attr}" == apps.* ]]; then
  app_program="$(nix eval --raw ".#${attr}.program" 2>/dev/null || true)"

  if [[ -n "${app_program}" && "${app_program}" != "null" ]]; then
    if [[ "${app_program}" == /nix/store/*/bin/* ]]; then
      out="${app_program%/bin/*}"
      resolved_from_app_program=1
    elif [[ "${app_program}" == /nix/store/* ]]; then
      out="${app_program}"
      resolved_from_app_program=1
    else
      echo "[nix-remote-copy][ERROR] app program for attr '${attr}' is not a store path: ${app_program}" >&2
      exit 1
    fi
  else
    # Backward-compatible fallback for flakes exposing apps and matching packages.
    build_attr="${attr/#apps./packages.}"
  fi
fi

if [[ "${resolved_from_app_program}" == "1" ]]; then
  # App metadata may point at a valid output path that is not realized locally.
  # Realize via the corresponding package attr before copy to avoid
  # "path is required, but there is no substituter that can build it".
  package_attr="${attr/#apps./packages.}"
  out="$(nix build ".#${package_attr}" -L -v -v --json --no-link | jq -r '.[0].outputs.out')"
  build_attr="${package_attr}"
fi

if [[ -z "${out}" ]]; then
  out=$(nix build ".#${build_attr}" -L -v -v --json --no-link | jq -r '.[0].outputs.out')
fi

if [[ -z "${out}" || "${out}" == "null" ]]; then
  echo "[nix-remote-copy][ERROR] failed to resolve output path for attr '${attr}' (build attr '${build_attr}')" >&2
  exit 1
fi

if [[ "${mode}" == "print" || "${mode}" == "--print-out-path" ]]; then
  printf '%s\n' "${out}"
  exit 0
fi

printf '[nix-remote-copy] copying output of attr "%s" (build attr "%s") to remote host "%s"...\n' "${attr}" "${build_attr}" "${target}" >&2
printf '%s\n' "${out}"
exec nix copy --no-check-sigs --to "ssh-ng://${target}?remote-program=/nix/var/nix/profiles/default/bin/nix-daemon" "${out}"
