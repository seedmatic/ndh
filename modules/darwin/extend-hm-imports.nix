{
  config,
  pkgs,
  lib,
  ...
}:
let
  isDarwin = pkgs.stdenv.isDarwin;
in
{
  hm.imports = (config.hm.imports) ++ [
    ../home-manager/ssh-keys.nix
  ];
}
