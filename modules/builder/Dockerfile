FROM nixos/nix:latest

SHELL [ "/usr/bin/env", "-S", "bash", "-ex", "-o", "pipefail", "-c" ]

ENV PS4="+ "

RUN <<EOS
    : enable flake builds
    cat <<'~' | cut -c 5- >> /etc/nix/nix.conf
    experimental-features = nix-command flakes 
~
    : configure the build folder
    git config --global init.defaultBranch master
    git init
    : install required nix CLI
    nix-env --install nixos-rebuild
EOS

WORKDIR /build

COPY flake.nix /build/

RUN <<EOS
    git add flake.nix
    exit 0
    nixos-rebuild switch --flake .#default --impure --accept-flake-config
EOS
