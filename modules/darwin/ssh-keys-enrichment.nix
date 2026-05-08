{
  config,
  pkgs,
  lib,
  catalog,
  inventory,
  ndh,
  self,
  ...
}:
let
  ndhCommon = "${self}/modules/.common.d";
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  profileName =
    if config ? profile && config.profile ? name then config.profile.name else "committed";
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
  generatedProfileKeysYamlPath = "${splitKeysDir}/profiles/${profileName}.yaml";

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

  loggerTagOrchestrate = "darwin.activationScripts.ssh-keys-enrichment.orchestrate";
  loggerTagEnrich = "darwin.activationScripts.ssh-keys-enrichment.enrichSSHKeysYaml";
  loggerTagSplit = "darwin.activationScripts.ssh-keys-enrichment.splitSSHKeysYaml";

  sshKeysEnrichmentTools = ndh.store.installBinScriptBundle "ssh-keys-enrichment-tools" {
    ssh-enrich-keys-yaml = pkgs.replaceVars "${ndhCommon}/ssh-keys.d/ssh-enrich-keys-yaml.sh" {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagEnrich;
    };
    ssh-split-keys-yaml = pkgs.replaceVars "${ndhCommon}/ssh-keys.d/ssh-split-keys-yaml.sh" {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagSplit;
    };
    ssh-enrich-split-and-authorize = pkgs.replaceVars "${ndhCommon}/ssh-keys.d/ssh-enrich-split-runtime-keys.sh" {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagOrchestrate;
    };
  };
in
{
  config.system.activationScripts.preActivation.text = lib.mkAfter ''
    set -euo pipefail
    ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-enrich-split-and-authorize \
      "${pkgs.bash}/bin/bash" \
      "${sshKeysEnrichmentTools}/bin/ssh-enrich-keys-yaml" \
      "${sshKeysEnrichmentTools}/bin/ssh-split-keys-yaml" \
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
