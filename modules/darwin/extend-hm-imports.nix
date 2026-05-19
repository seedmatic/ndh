{
  config,
  pkgs,
  lib,
  paths,
  ...
}:
let
  isDarwin = pkgs.stdenv.isDarwin;
in
{
  hm.imports = (config.hm.imports) ++ [
    paths.modulesHomeManagerSshKeys
  ];
}
