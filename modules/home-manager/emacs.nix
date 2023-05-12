{
  lib, pkgs, ...
}: {
  programs.emacs = {
    enable = true;
  };
  services.emacs = lib.mkIf (!pkgs.stdenvNoCC.isDarwin) {
    enable = true;
  };
}


