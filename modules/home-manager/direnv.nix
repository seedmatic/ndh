{...}: {
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;

    stdlib = ''
      source_if_exists() {
        local file=''${1}
        [ ! -f ''${file} ] && return
        source ''${file}
      }

      direnv_layout_dir() {
        local pwd_hash
        pwd_hash=$(basename "$PWD")-$(echo -n "$PWD" | shasum | cut -d ' ' -f 1 | head -c 7)
        echo "$XDG_CACHE_HOME/direnv/layouts/$pwd_hash"
      }

      source_if_exists ''${BASH_SOURCE}~$(uname)
      source_if_exists ''${BASH_SOURCE}~$(hostname)

      source_if_exists ''${BASH_SOURCE}~golang
      source_if_exists ''${BASH_SOURCE}~krew
      source_if_exists ''${BASH_SOURCE}~pass
    '';
  };
}
