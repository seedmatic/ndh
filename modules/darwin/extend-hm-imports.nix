{
  config,
  pkgs,
  lib,
  self,
  ...
}:
let
  isDarwin = pkgs.stdenv.isDarwin;
in
{
  hm.imports = (config.hm.imports) ++ [
    "${self}/modules/home-manager/ssh-keys.nix"
  ];
}
