{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    bfg-repo-cleaner
  ];
}
