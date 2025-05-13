{
  config,
  pkgs,
  ...
}: {
  programs.chromium = {
    enable = false;
  };
}
