#!/usr/bin/env -S bash -exuo pipefail

host=$1; shift
exec nix copy --to "ssh-ng://${host}?remote-program=/nix/var/nix/profiles/default/bin/nix-daemon" $*
