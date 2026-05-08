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
  homeDir = config.home.homeDirectory;
  sshPaths = config.sshPaths;
  loggerTag = "home-manager.activationScripts.${userName}.provisionLimaRdpAssets";

  provisionLimaAssetsScript = pkgs.replaceVars ./lima-rdp-assets.d/provision.sh {
    nixBashTrampoline = nixBashTrampoline;
    loggerTag = loggerTag;
    homeDir = homeDir;
    privateKey = sshPaths.privKeyFile;
    publicKey = sshPaths.hostPublicKeyFile;
  };
in
{
  imports = [ "${self}/modules/.common.d/ssh-paths.nix" ];

  home.activation.provisionLimaRdpAssets = lib.hm.dag.entryAfter [ "extractSSHKeys" ] ''
    ${pkgs.bash}/bin/bash ${provisionLimaAssetsScript}
  '';
}
