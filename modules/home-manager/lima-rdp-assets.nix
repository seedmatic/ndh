{
  config,
  lib,
  pkgs,
  ...
}:
let
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;
  homeDir = config.home.homeDirectory;
  sshPaths = config.sshPaths;
  logger = config._module.specialArgs.ndh.logger.script;
  loggerTag = "home-manager.activationScripts.${userName}.provisionLimaRdpAssets";

  provisionLimaAssetsScript = pkgs.replaceVars ./lima-rdp-assets.d/provision.sh {
    bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
    logger = logger;
    loggerTag = loggerTag;
    homeDir = homeDir;
    privateKey = sshPaths.privKeyFile;
    publicKey = sshPaths.hostPublicKeyFile;
  };
in
{
  imports = [ ../.common.d/ssh-paths.nix ];

  home.activation.provisionLimaRdpAssets = lib.hm.dag.entryAfter [ "extractSSHKeys" ] ''
    ${pkgs.bash}/bin/bash ${provisionLimaAssetsScript}
  '';
}
