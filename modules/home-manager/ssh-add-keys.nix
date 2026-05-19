{
  config,
  pkgs,
  lib,
  worktreePath,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  specialArgs =
    if config ? _module && config._module ? specialArgs then config._module.specialArgs else { };
  nixBashTrampoline =
    if
      specialArgs ? ndh && specialArgs.ndh ? context && specialArgs.ndh.context ? nixBashTrampoline
    then
      "${specialArgs.ndh.context.nixBashTrampoline}"
    else
      "${worktreePath.of "modules/.common.d/shell.d/nix-bash-trampoline.sh"}";
  user = config.profile.user;
  userName = user.name;
  userHome = user.home;
  cfg = config.ssh-add-keys;
  sshPaths = config.sshPaths;
  loggerTag = "home-manager.ssh-add-keys";
  keysFileDefault = "${sshPaths.secretsKeysDir}.yaml";
  allowedKeyNamesDefault = [ sshPaths.keyName ];
  allowedKeyNamesCsv = lib.concatStringsSep "," cfg.allowedKeyNames;
  renderedSshAddKeysScript = pkgs.replaceVars ./ssh-key.d/ssh-add-keys.sh {
    nixBashTrampoline = nixBashTrampoline;
    loggerTag = loggerTag;
    allowedKeyNamesCsv = allowedKeyNamesCsv;
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
  imports = [ (worktreePath.of "modules/.common.d/ssh-paths.nix") ];

  options.ssh-add-keys = {
    enable = mkEnableOption "Enable loading private keys from the generated keys.yaml into ssh-agent.";

    keyFile = mkOption {
      type = types.str;
      default = keysFileDefault;
      description = "Path to the decrypted YAML file containing SSH keys.";
    };

    allowedKeyNames = mkOption {
      type = types.listOf types.str;
      default = allowedKeyNamesDefault;
      description = "SSH key names from keys.yaml allowed to be loaded into agent and managed authorized_keys block.";
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
