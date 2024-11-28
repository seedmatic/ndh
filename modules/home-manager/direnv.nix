{ pkgs, ... }: let
  dollar = "$";
in {
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;

    stdlib = ''
      direnv_layout_dir() {
        local pwd_hash
        pwd_hash=${dollar}(basename "${dollar}PWD")-${dollar}(echo -n "${dollar}PWD" | shasum | cut -d ' ' -f 1 | head -c 7)
        echo "${dollar}XDG_CACHE_HOME/direnv/layouts/${dollar}pwd_hash"
      }

      source_env_if_exists ''${dollar}{BASH_SOURCE}~${dollar}(uname)
      source_env_if_exists ''${dollar}{BASH_SOURCE}~${dollar}(hostname)
    '';

  };
}
