{
  config,
  pkgs,
  lib,
  catalog,
  inventory,
  ...
}:
let
  profileName =
    if config ? profile && config.profile ? name then config.profile.name else "committed";
  sshKeyProfileName =
    if
      config ? profile && config.profile ? sshKeyProfileName && config.profile.sshKeyProfileName != null
    then
      config.profile.sshKeyProfileName
    else
      profileName;
  hostIdent =
    if
      config ? profile
      && config.profile ? host
      && config.profile.host ? hostAlias
      && config.profile.host.hostAlias != null
      && config.profile.host.hostAlias != ""
    then
      config.profile.host.hostAlias
    else if
      config ? profile
      && config.profile ? host
      && config.profile.host ? hostName
      && config.profile.host.hostName != null
    then
      config.profile.host.hostName
    else if config.networking.hostName != "" then
      config.networking.hostName
    else
      "darwin";
  profileUserName =
    if config ? profile && config.profile ? user && config.profile.user ? name then
      config.profile.user.name
    else
      "root";
  decryptedSSHKeysYamlPath = config.sshPaths.runtimeSecretsKeysYaml;
  splitKeysDir = "/run/secrets/nix-darwin-home/ssh-keys-split.d";
  generatedKeysYamlPath = "${splitKeysDir}/keys.generated.yaml";
  generatedSystemKeysYamlPath = "${splitKeysDir}/system.yaml";
  generatedProfileKeysYamlPath = "${splitKeysDir}/profiles/${sshKeyProfileName}.yaml";

  inventoryHostNames = builtins.attrNames (inventory.hosts or { });
  inventoryHostsCsv = lib.concatStringsSep "," inventoryHostNames;

  catalogUsers = if catalog ? users then catalog.users else { };
  profileOwnerName =
    if
      builtins.hasAttr profileName catalogUsers
      && catalogUsers.${profileName} ? name
      && catalogUsers.${profileName}.name != null
    then
      catalogUsers.${profileName}.name
    else
      profileUserName;

  logger = config.nixBashLogger.script;
  loggerTagOrchestrate = "darwin.activationScripts.ssh-keys-enrichment.orchestrate";
  loggerTagEnrich = "darwin.activationScripts.ssh-keys-enrichment.enrichSSHKeysYaml";
  loggerTagSplit = "darwin.activationScripts.ssh-keys-enrichment.splitSSHKeysYaml";
  sshEnrichKeysYamlScriptSource = pkgs.replaceVars ../.common.d/ssh-keys.d/ssh-enrich-keys-yaml.sh {
    bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
    logger = logger;
    loggerTag = loggerTagEnrich;
  };
  sshEnrichKeysYamlScript = pkgs.runCommand "ndh-ssh-enrich-keys-yaml-darwin.sh" { } ''
    install -m 0555 ${sshEnrichKeysYamlScriptSource} "$out"
  '';
  sshSplitKeysYamlScriptSource = pkgs.replaceVars ../.common.d/ssh-keys.d/ssh-split-keys-yaml.sh {
    bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
    logger = logger;
    loggerTag = loggerTagSplit;
  };
  sshSplitKeysYamlScript = pkgs.runCommand "ndh-ssh-split-keys-yaml-darwin.sh" { } ''
    install -m 0555 ${sshSplitKeysYamlScriptSource} "$out"
  '';
  sshEnrichAndSplitKeysYamlScriptSource =
    pkgs.replaceVars ../.common.d/ssh-keys.d/ssh-enrich-split-runtime-keys.sh
      {
        bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
        logger = logger;
        loggerTag = loggerTagOrchestrate;
      };
  sshEnrichAndSplitKeysYamlScript =
    pkgs.runCommand "ndh-ssh-enrich-and-split-keys-yaml-darwin.sh" { }
      ''
        install -m 0555 ${sshEnrichAndSplitKeysYamlScriptSource} "$out"
      '';
in
{
  config.system.activationScripts.preActivation.text = lib.mkAfter ''
    set -euo pipefail
    ${pkgs.bash}/bin/bash ${sshEnrichAndSplitKeysYamlScript} \
      "${pkgs.bash}/bin/bash" \
      "${sshEnrichKeysYamlScript}" \
      "${sshSplitKeysYamlScript}" \
      "${sshKeyProfileName}" \
      "${hostIdent}" \
      "${decryptedSSHKeysYamlPath}" \
      "${generatedKeysYamlPath}" \
      "${inventoryHostsCsv}" \
      "${profileOwnerName}" \
      "${splitKeysDir}" \
      "${generatedSystemKeysYamlPath}" \
      "${generatedProfileKeysYamlPath}"
  '';
}
