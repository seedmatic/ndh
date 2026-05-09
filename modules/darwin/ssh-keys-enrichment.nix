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
  # Outside the sops-install-secrets namespace so that unit's strict
  # directory-replacement sweep does not nuke our enrichment outputs.
  splitKeysDir = "/run/ndh/ssh-keys-split.d";
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

  loggerTagExtractSystem = "darwin.activationScripts.ssh-keys-enrichment.extractSystemKeys";

  sshExtractKeysSplitExpFile = ndh.store.runCommand "ssh-extract-keys.split-exp.yq" { } ''
    install -m 0444 "${self}/modules/home-manager/ssh-key.d/ssh-extract-keys.split-exp.yq" "$out"
  '';

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
    # Same extract script HM uses, but parameterized with systemKeysDir so the
    # ssh-host-scope privates land at /var/lib/ndh/ssh-keys (root-owned) when
    # this runs from the root-context activation below.
    ssh-extract-keys = pkgs.replaceVars "${self}/modules/home-manager/ssh-key.d/ssh-extract-keys.sh" {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagExtractSystem;
      splitExpFile = sshExtractKeysSplitExpFile;
    };
  };

  # Scratch dir for the system-side extract pass: we only care about what
  # lands in systemKeysDir (4th arg below). User-scope privates for this
  # profile are still materialized by the home-manager activation from
  # modules/home-manager/ssh-keys.nix, so we point the script's userOutputDir
  # at a root-owned throwaway so it does not clobber ~/.local/var/run/secrets.
  systemExtractScratchDir = "/var/lib/ndh/ssh-keys-extract-scratch";
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

    # Harvest system-private key material (ssh-host scope) into
    # sshPaths.systemKeysDir so nix-store-identity-deploy can pick them up.
    # Scratch dir holds the user/authority duplicates we do not need here.
    install -d -m 0700 ${lib.escapeShellArg systemExtractScratchDir}
    ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-extract-keys \
      ${lib.escapeShellArg generatedKeysYamlPath} \
      ${lib.escapeShellArg systemExtractScratchDir} \
      root \
      ${lib.escapeShellArg config.sshPaths.systemKeysDir}
  '';
}
