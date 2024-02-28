{
  config,
  pkgs,
  ...
}: {
  programs.chromium = {
    enable = false;
    package = pkgs.chromium;
  };
}
