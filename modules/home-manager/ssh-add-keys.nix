{
  config,
  pkgs,
  lib,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.ssh-add-keys;
  keysFileDefault = "/run/secrets/nix-darwin-home/nxmatic-ssh-keys.yaml";
  sshAddKeysStoreScript = pkgs.writeShellApplication {
    name = "ssh-add-keys";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      gawk
      gnugrep
      keychain
      openssh
      yq-go
    ];
    text = ''
      exec ${pkgs.bash}/bin/bash ${./ssh-add-keys.sh} "$@"
    '';
  };
in
{
  options.ssh-add-keys = {
    enable = mkEnableOption "Enable loading private keys from the generated keys.yaml into ssh-agent.";

    keyFile = mkOption {
      type = types.str;
      default = keysFileDefault;
      description = "Path to the decrypted YAML file containing SSH keys.";
    };
  };

  config = mkIf cfg.enable {
    launchd.agents.ssh-add-keys = {
      enable = true;
      config = {
        Label = "io.nxmatic.nix-darwin-home.home.ssh-add-keys";
        Debug = true;
        ProgramArguments = [
          "${sshAddKeysStoreScript}/bin/ssh-add-keys"
          "${cfg.keyFile}"
        ];
        RunAtLoad = true;
        KeepAlive = false;
      };
    };
  };
}
