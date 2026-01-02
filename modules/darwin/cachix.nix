{
  config,
  pkgs,
  lib,
  ...
}:

{
  # Install cachix package system-wide
  environment.systemPackages = with pkgs; [
    cachix
  ];
}
