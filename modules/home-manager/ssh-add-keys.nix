{ config, pkgs, lib, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.home-manager.ssh-add-keys;
  homeDir = config.home.homeDirectory;
  keysFileDefault = "${homeDir}/.ssh/keys.yaml";
in
{
  options.home-manager.ssh-add-keys = {
    enable = mkEnableOption "Enable the ssh-add-keys agent.";

    keyFile = mkOption {
      type = types.path;
      default = keysFileDefault;
      description = "Path to the decrypted YAML file containing SSH keys.";
    };
  };

  config = mkIf cfg.enable {

    home.file.".ssh/add-keys.sh" = {
      text = ''
        #!/usr/bin/env -S bash -exuo pipefail
        
        # Check that the keys file exists
        if [ ! -f "${cfg.keyFile}" ]; then
          echo "SSH keys YAML file not found: ${cfg.keyFile}"
          exit 1
        fi

        # Load the SSH agent using keychain
        eval "$(${ lib.getExe pkgs.keychain } -q --confhost --agents ssh --eval)"
       
        # Extract private keys from the YAML file and add them to the SSH agent
        ${ lib.getExe pkgs.yq-go } eval ".keys[].private" "${cfg.keyFile}" | while IFS= read -r line; do
          if [[ "$line" == "-----BEGIN OPENSSH PRIVATE KEY-----"* ]]; then
            key="$line"
            # Read the multiline key until its terminator is reached
            while IFS= read -r line; do
              key=$( printf "%s\n%s" "$key" "$line" )
              if [[ "$line" == "-----END OPENSSH PRIVATE KEY-----" ]]; then
                break
              fi
            done
            # Add the complete key to the SSH agent
            printf "%s\n" "$key" | ${pkgs.openssh}/bin/ssh-add - 2>/dev/null || {
              echo "Failed to add an SSH key." >&2
            }
          fi
        done
      '';
      executable = true;
    };

    launchd.agents.ssh-add-keys = {
      enable = true;
      config = {
        Label = "org.nix-community.home.ssh-add-keys";
        Debug = true;
        ProgramArguments = [
          "${homeDir}/.ssh/add-keys.sh"
        ];
        RunAtLoad = true;
        KeepAlive = false;
      };
    };
  };
}
