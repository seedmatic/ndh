{
  lib,
  pkgs,
  ...
}: {
  programs.firefox = {
    enable = false;
    package = pkgs.firefox;
  };
}
