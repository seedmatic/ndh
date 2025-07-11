{ pkgs, ... }: let

  dollar = "$";

  use-flox-rc-path = pkgs.writeScript "direnv-use-flox.rc" (builtins.readFile ./direnv-use-flox.rc);
  flox-rc-path = pkgs.writeScript "flox.rc.sh" (builtins.readFile ./flox.rc);

in {
  programs.direnv = {

    stdlib = ''
      PATH_add /run/current-system/sw/bin
      export FLOX_RCPATH="${flox-rc-path}"

      source_env "${use-flox-rc-path}"
    '';
  };
}
