{ config, pkgs, lib, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.home-manager.ssh-add-keys;
  homeDir = config.home.homeDirectory;
  keysFile = "${homeDir}/.ssh/keys.yaml";
in
{
  options.home-manager.ssh-add-keys = {

    enable = mkEnableOption "Enable the ssh-add-keys agent.";

    keyFile = mkOption {
      type = types.str;
      default = keysFile;
      description = "Path to the decrypted YAML file containing SSH keys.";
    };

  };

  config = mkIf cfg.enable {

    home.file.".ssh/add-keys.sh" = {
      text = ''
        #!/bin/bash
        # Extract the private keys from the YAML file
        ${pkgs.yq-go}/bin/yq e ".keys[].private" ${cfg.keyFile} | while IFS= read -r line; do
          if [[ "$line" == "-----BEGIN OPENSSH PRIVATE KEY-----"* ]]; then
            # Read the entire private key
            key="$line"
            while IFS= read -r line; do
              key+=$'\n'"$line"
              [[ "$line" == "-----END OPENSSH PRIVATE KEY-----" ]] && break
            done
            # Add the private key to the SSH agent
            ${pkgs.openssh}/bin/ssh-add - <<< "$key"
          fi
        done
      '';
      executable = true;
    };

    launchd.agents.ssh-add-keys = {
      enable = true;

      config = {
        Label = "org.nix-community.home.ssh-add-keys";
        EnvironmentVariables = {
          SSH_AUTH_SOCK = "${homeDir}/Library/Containers/com.apple.sshd/ssh-agent.socket";
        };
        ProgramArguments = [
          "${homeDir}/.ssh/add-keys.sh"
        ];
        RunAtLoad = true;
        KeepAlive = false;
        StandardErrorPath = "${homeDir}/.ssh/ssh-add-keys.err";
        StandardOutPath = "${homeDir}/.ssh/ssh-add-keys.out";
      };
    };
  };
}