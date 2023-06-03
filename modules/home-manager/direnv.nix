{...}: {
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;

    enableZshIntegration = true;

    stdlib = ''
      direnv_layout_dir() {
        local pwd_hash
        pwd_hash=$(basename "$PWD")-$(echo -n "$PWD" | shasum | cut -d ' ' -f 1 | head -c 7)
        echo "$XDG_CACHE_HOME/direnv/layouts/$pwd_hash"
      }

      source_env_if_exists ''${BASH_SOURCE}~$(uname)
      source_env_if_exists ''${BASH_SOURCE}~$(hostname)

      source_env_if_exists ''${BASH_SOURCE}~golang
      source_env_if_exists ''${BASH_SOURCE}~krew
      source_env_if_exists ''${BASH_SOURCE}~pass
    '';
  };
}
