{
  config,
  lib,
  pkgs,
  ...
}:
let
  dollar = "$";
in
{
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;

    stdlib = lib.mkBefore ''
      # exec 5> $HOME/.local/direnv-bash.log
      # BASH_XTRACEFD="5"
      # PS4='[${dollar}{BASH_SOURCE[0]:-inherited}:${dollar}{LINENO}:${dollar}{FUNCNAME[0]:-main}] '
      # set -x

      direnv_layout_dir() {
        local pwd_hash
        pwd_hash=${dollar}(basename "${dollar}PWD")-${dollar}(echo -n "${dollar}PWD" | shasum | cut -d ' ' -f 1 | head -c 7)
        echo "${dollar}XDG_CACHE_HOME/direnv/layouts/${dollar}pwd_hash"
      }

      my:source_env() {
        local base_path="${dollar}{BASH_SOURCE}"
        local suffix="$1"
        local env_file="${dollar}{base_path}.${dollar}{suffix}"
        if [ ! -f "$env_file" ]; then
          return
        fi
        log_status "Sourcing environment file: $env_file"
        source_env "$env_file"
      }

      my:source_env $(uname)
      my:source_env $(hostname)
    '';

  };

  home.file."${config.xdg.configHome}/direnv/direnv.toml".text = ''
    [whitelist]
    prefix = [ 
      # MacOS
      "/private/var/lib/git", 
      "/Volumes/Eclipse", 
      "/Users/nxmatic", 
      "/Users/stephane.lacoin",
      # Linux
      "/var/lib/git", 
      "/home/stephane.lacoin", 
      "/home/nxmatic"
    ]
  '';
}
