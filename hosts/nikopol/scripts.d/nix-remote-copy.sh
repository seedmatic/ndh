#!/usr/bin/env -S bash -exuo pipefail

host=$1; shift
out=$( nix build .#homeManagerConfiguration.activationPackage --json --no-link |
       yq -pjson '.[0].outputs.out' )
exec nix copy --to "ssh-ng://${host}?remote-program=/nix/var/nix/profiles/default/bin/nix-daemon" "${out}"
