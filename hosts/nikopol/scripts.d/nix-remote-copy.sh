#!/usr/bin/env -S bash -exuo pipefail

attr=${1:-homeManagerConfigurations.work.activationPackage}
mode=${2:-copy}

build_attr="${attr}"
if [[ "${attr}" == apps.* ]]; then
       build_attr="${attr/#apps./packages.}"
fi

out=$( nix build ".#${build_attr}" -L -v -v --json --no-link |
       jq -r '.[0].outputs.out' )

if [[ -z "${out}" || "${out}" == "null" ]]; then
       echo "[nix-remote-copy][ERROR] failed to resolve output path for attr '${attr}' (build attr '${build_attr}')" >&2
       exit 1
fi

if [[ "${mode}" == "print" || "${mode}" == "--print-out-path" ]]; then
       printf '%s\n' "${out}"
       exit 0
fi

exec nix copy --no-check-sigs --to "ssh-ng://vz-host.nikopol?remote-program=/nix/var/nix/profiles/default/bin/nix-daemon" "${out}"
