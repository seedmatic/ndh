{
  config,
  lib,
  pkgs,
  ...
}:

let
  shellKeychainInit = pkgs.replaceVars ./ssh-keychain.d/shell-init.sh {
    keychainBin = "${pkgs.keychain}/bin/keychain";
    sshAddBin = "${pkgs.openssh}/bin/ssh-add";
    sshKeygenBin = "${pkgs.openssh}/bin/ssh-keygen";
    launchctlBin = "/bin/launchctl";
  };
in

{
  # System-wide shell configuration for keychain initialization
  # This adds keychain support to all interactive shells for all users.
  # Logic is externalized to avoid Nix string interpolation hazards and to
  # resolve runtime-managed SSH key filenames from ssh-keys.d/agent-keys.
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
