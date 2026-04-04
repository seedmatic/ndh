{
  config,
  lib,
  pkgs,
  ...
}:

let
  sshPaths = config.sshPaths;
  shellKeychainInit = pkgs.replaceVars ./ssh-keychain.d/shell-init.sh {
    keychainBin = "${pkgs.keychain}/bin/keychain";
    sshAddBin = "${pkgs.openssh}/bin/ssh-add";
    sshKeygenBin = "${pkgs.openssh}/bin/ssh-keygen";
    launchctlBin = "/bin/launchctl";
    userKeysDir = sshPaths.perUserSecretsDir;
    keysYamlPath = sshPaths.generatedKeysYamlFile;
  };
in

{
  imports = [ ../common/ssh-paths.nix ];

  # System-wide shell configuration for keychain initialization
  # This adds keychain support to all interactive shells for all users.
  # Logic is externalized to avoid Nix string interpolation hazards and to
  # resolve runtime-managed SSH key filenames from canonical /run/secrets-per-user paths.
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
