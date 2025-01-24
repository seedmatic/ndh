{ lib, pkgs, ... }: {

  programs.emacs = {
    enable = true;
    package = pkgs.emacs-nox;
  };

  imports = [  ./emacs-daemon.nix ];
}


