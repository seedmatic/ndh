{
  config,
  lib,
  pkgs,
  ...
}:
let
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;
  logger = lib.attrByPath [
    "_module"
    "specialArgs"
    "logger"
    "script"
  ] ../common/shell.d/logger.sh config;
  loggerTag = "home-manager.activationScripts.${userName}.removeUseKeychain";
in
# Remove any UseKeychain directive from ~/.ssh/config (@codebase)
# Always run using GNU sed from Nix store; no pre-checks required. Idempotent.
# Pattern: a line consisting solely of optional leading whitespace, 'UseKeychain'
# one or more spaces, 'yes', optional trailing whitespace or inline comment.
{
  home.activation.removeUseKeychain =
    let
      removeUseKeychainScript = pkgs.replaceVars ./ssh-keychain-removal.d/remove-use-keychain.sh {
        logger = logger;
        loggerTag = loggerTag;
      };
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.bash}/bin/bash ${removeUseKeychainScript}
    '';
}
