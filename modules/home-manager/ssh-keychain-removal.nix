{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  specialArgs =
    if config ? _module && config._module ? specialArgs then config._module.specialArgs else { };
  nixBashTrampoline =
    if
      specialArgs ? ndh && specialArgs.ndh ? context && specialArgs.ndh.context ? nixBashTrampoline
    then
      "${specialArgs.ndh.context.nixBashTrampoline}"
    else
      "${self}/modules/.common.d/shell.d/nix-bash-trampoline.sh";
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;
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
        nixBashTrampoline = nixBashTrampoline;
        loggerTag = loggerTag;
      };
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.bash}/bin/bash ${removeUseKeychainScript}
    '';
}
