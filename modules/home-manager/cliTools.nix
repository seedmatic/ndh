{pkgs, ...}: {
  programs.cliTools.mvnd = {
    enable = true;
    package = pkgs.maven-mvnd-m39;
  };
}
