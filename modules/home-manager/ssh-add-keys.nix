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
  user = config.profile.user;
  userName = user.name;
  userHome = user.home;
  cfg = config.ssh-add-keys;
  sshPaths = config.sshPaths;
  keysFileDefault = "${sshPaths.secretsKeysDir}.yaml";
  renderedSshAddKeysScript = pkgs.replaceVars ./ssh-key.d/ssh-add-keys.sh {
    bashTrampoline = "${../common/shell.d/nix-bash-trampoline.sh}";
    logger = config._module.specialArgs.logger.script;
  };
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
      exec ${pkgs.bash}/bin/bash ${renderedSshAddKeysScript} "$@"
    '';
  };
in
{
  imports = [ ../common/ssh-paths.nix ];

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
