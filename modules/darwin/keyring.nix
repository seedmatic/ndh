{
  config,
  lib,
  pkgs,
  catalog,
  ...
}:
# ndh-keyring on the operator seat's PATH: the operator generates the machines' host keys into their keyring.
# A gesture, never run by the activation. The operator's own age identity lives there too, as seedmatic/age-key/operator,
# never on disk: every sops on this seat reads it through SOPS_AGE_KEY_CMD, in shells and GUI apps alike (the git
# smudge in VSCode), so the command carries its own pass, store and gpg home rather than the shell's.
let
  user = config.profile.user.name;
  hm = config.home-manager.users.${user};
in
{
  options.ndh.keyring = {
    enable = lib.mkEnableOption "ndh-keyring on this operator seat (the one holding the keyring)";
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/keyring.d/package.nix {
        inherit pkgs lib;
        netplan = catalog.netplan;
      };
      description = "ndh-keyring, built for this seat: on its PATH when enabled, and one of ndh-ops's tools.";
    };
    ageKeyCommand = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = pkgs.writeShellScript "sops-age-key-operator" ''
        export PASSWORD_STORE_DIR=${lib.escapeShellArg hm.programs.password-store.settings.PASSWORD_STORE_DIR}
        export GNUPGHOME=${lib.escapeShellArg hm.programs.gpg.homedir}
        exec ${hm.programs.password-store.package}/bin/pass show seedmatic/age-key/operator
      '';
      description = "SOPS_AGE_KEY_CMD on this seat: prints the operator's age identity from the keyring, to sops alone.";
    };
  };

  config = lib.mkIf config.ndh.keyring.enable {
    environment.systemPackages = [ config.ndh.keyring.package ];
    home-manager.users.${user}.home.sessionVariables.SOPS_AGE_KEY_CMD =
      "${config.ndh.keyring.ageKeyCommand}";
    # GUI-launched processes read the launchd session's environment, not the shell's (see claude-code-backend.nix).
    launchd.user.agents.sops-age-key-cmd = {
      command = "/bin/launchctl setenv SOPS_AGE_KEY_CMD ${config.ndh.keyring.ageKeyCommand}";
      serviceConfig = {
        Label = "io.seedmatic.ndh.sops-age-key-cmd";
        RunAtLoad = true;
      };
    };
  };
}
