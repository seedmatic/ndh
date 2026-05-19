{
  config,
  pkgs,
  lib,
  worktreePath,
  ...
}:
let
  isDarwin = pkgs.stdenv.isDarwin;
in
{
  hm.imports = (config.hm.imports) ++ [
    (worktreePath.of "modules/home-manager/ssh-keys.nix")
  ];
}
