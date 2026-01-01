{ pkgs, ... }:
with pkgs; [
    bash
    coreutils-full
    direnv
    git
    gitflow
    emacs-nox
    remake
    powerline-fonts
    powerline-go
    powerline-symbols
    ripvcs
    sops
    ssh-to-age
    yq-go
    zsh
]
