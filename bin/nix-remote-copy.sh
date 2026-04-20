#!/usr/bin/env -S bash -euo pipefail

# Usage:
#   ./bin/nix-remote-copy.sh [attr] [mode] [target]
#
# Positional defaults:
#   attr   = homeManagerConfigurations.bringup.activationPackage
#   mode   = copy   (or: print / --print-out-path)
#   target = vz-host.nikopol
#
# Environment override:
#   NIX_REMOTE_COPY_TARGET

attr="${1:-homeManagerConfigurations.nikopol.bringup.activationPackage}"
mode="${2:-copy}"
target="${3:-${NIX_REMOTE_COPY_TARGET:-vz-host.nikopol}}"

build_attr="${attr}"
if [[ "${attr}" == apps.* ]]; then
  build_attr="${attr/#apps./packages.}"
fi

out=$(nix build ".#${build_attr}" -L -v -v --json --no-link | jq -r '.[0].outputs.out')

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
