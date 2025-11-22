{ pkgs, lib ? pkgs.lib, programs ? { }, ... }:
let
  floxNames =
    if programs ? floxEnv && programs.floxEnv ? packages
    then map (pkg: pkg.name) programs.floxEnv.packages
    else [];

  isFloxManaged = pkg: builtins.elem (lib.getName pkg) floxNames;

  basePackages = with pkgs; [
    bash
    coreutils-full
    direnv
    flox
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
  ];
in
lib.filter (pkg: !isFloxManaged pkg) basePackages
