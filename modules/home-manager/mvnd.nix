{ self, ... }:
{
  programs.maven-mvnd = {
    enable = true;
    package = pkgs.maven-mvnd-m39;
    command = "mvnd.sh";
  };
}
