{
  lib, pkgs, ...
}: {
  programs.emacs = {
    enable = true;
    package = pkgs.emacs-nox;
  };
  services.emacs = lib.mkIf (!pkgs.stdenvNoCC.isDarwin) {
    enable = true;
  };
}


