{
  config,
  lib,
  pkgs,
  ...
}:
let
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;
  activationLogger = lib.attrByPath [
    "_module"
    "specialArgs"
    "activationLogger"
    "script"
  ] ../common/default.d/activation-logger.sh config;
  activationTag = "home-manager.activationScripts.${userName}.removeUseKeychain";
in
# Remove any UseKeychain directive from ~/.ssh/config (@codebase)
# Always run using GNU sed from Nix store; no pre-checks required. Idempotent.
# Pattern: a line consisting solely of optional leading whitespace, 'UseKeychain'
# one or more spaces, 'yes', optional trailing whitespace or inline comment.
{
  home.activation.removeUseKeychain = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    builtins.readFile (
      pkgs.replaceVars ./ssh-keychain-removal.d/remove-use-keychain.sh {
        sed = "${pkgs.gnused}/bin/sed";
        activationLogger = activationLogger;
        activationTag = activationTag;
      }
    )
  );
}
