{ lib, pkgs, ... }:
let
  use-flox-rc-path = pkgs.writeScript "direnv-use-flox.rc" (builtins.readFile ./direnv-use-flox.rc);
in
{
  programs.direnv = {

    stdlib = lib.mkAfter ''
      ${lib.optionalString pkgs.stdenvNoCC.isLinux "PATH_add /run/wrappers/bin"}
      PATH_add /run/current-system/sw/bin

      source_env "${use-flox-rc-path}"
    '';
  };
}
