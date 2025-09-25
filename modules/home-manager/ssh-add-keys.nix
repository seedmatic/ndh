{ config, pkgs, lib, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.ssh-add-keys;
  homeDir = config.home.homeDirectory;
  keysFileDefault = "${homeDir}/.ssh/keys.yaml";
in
{
  options.ssh-add-keys = {
    enable = mkEnableOption "Enable loading private keys from the generated keys.yaml into ssh-agent.";

    keyFile = mkOption {
      type = types.path;
      default = keysFileDefault;
      description = "Path to the decrypted YAML file containing SSH keys.";
    };
  };

  config = mkIf cfg.enable {
    # Install the external loader script referencing the generated YAML keys file
    home.file.".ssh/load-yaml-keys.sh" = {
      source = ./ssh-agent-load-keys.sh;
      executable = true;
    };

    launchd.agents.ssh-add-keys = {
      enable = true;
      config = {
        Label = "org.nix-community.home.ssh-add-keys";
        Debug = true;
        ProgramArguments = [
          "${homeDir}/.ssh/load-yaml-keys.sh" "${cfg.keyFile}"
        ];
        RunAtLoad = true;
        KeepAlive = false;
      };
    };
  };
}
