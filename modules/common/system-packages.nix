{ pkgs, ... }:
with pkgs; [
  bash
  coreutils-full
  direnv
  # flox installed via flox itself before bootstrap
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
