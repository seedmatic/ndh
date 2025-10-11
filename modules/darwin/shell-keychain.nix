{ config, lib, pkgs, ... }:

{
  # System-wide shell configuration for keychain initialization
  # This adds keychain support to all interactive shells for all users

  # Configure system shells to initialize keychain automatically
  programs.bash = {
    enable = true;
    interactiveShellInit = ''
      # Initialize keychain with Lima SSH key for interactive shells
      if command -v keychain >/dev/null 2>&1; then
        # Only initialize if Lima SSH key exists
        if [[ -f "$HOME/.lima/_config/user" ]]; then
          eval $(keychain --quiet --eval ~/.lima/_config/user)
        fi
      fi
    '';
  };

  programs.zsh = {
    enable = true;
    interactiveShellInit = ''
      # Initialize keychain with Lima SSH key for interactive shells
      if command -v keychain >/dev/null 2>&1; then
        # Only initialize if Lima SSH key exists
        if [[ -f "$HOME/.lima/_config/user" ]]; then
          eval $(keychain --quiet --eval ~/.lima/_config/user)
        fi
      fi
    '';
  };
}
