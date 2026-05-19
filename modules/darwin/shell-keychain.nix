{
  config,
  lib,
  pkgs,
  paths,
  ...
}:

let
  sshPaths = config.sshPaths;
  shellKeychainInit = pkgs.replaceVars ./ssh-keychain.d/shell-init.sh {
    perUserKeysDir = sshPaths.secretsKeysDir;
  };
in

{
  imports = [ paths.modulesCommonSshPaths ];

  # System-wide shell configuration for keychain initialization
  # This adds keychain support to all interactive shells for all users.
  # Logic is externalized to avoid Nix string interpolation hazards and to
  # resolve runtime-managed SSH key filenames from canonical sshPaths runtime paths.
  programs.bash = {
    enable = true;
    interactiveShellInit = ''
      source ${shellKeychainInit}
    '';
  };

  # Configure system zsh shells to initialize keychain automatically
  programs.zsh = {
    enable = true;
    interactiveShellInit = ''
      source ${shellKeychainInit}
    '';
  };
}
