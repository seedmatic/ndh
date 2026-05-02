{
  config,
  pkgs,
  lib,
  ndh,
  ndhSystemd,
  ...
}:
let
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  catalog = ndhContext.catalog;
  inventory = ndhContext.inventory;
  keysTargetUnit = "keys.target";
  hasSopsInstallSecretsService = builtins.hasAttr "sops-install-secrets" config.systemd.services;
  hasLimaCloudInitService = builtins.hasAttr (ndhSystemd.mkUnitName "lima-cloud-init") config.systemd.services;
  contributedTargetName = ndhSystemd.contributedTargetName;
  limaCloudInitServiceName = ndhSystemd.mkServiceName "lima-cloud-init";
  hostkeyEnrollmentCheckServiceName = ndhSystemd.mkServiceName "hostkey-enrollment-check";
  profileUserName =
    if config ? profile && config.profile ? user && config.profile.user ? name then
      config.profile.user.name
    else
      "root";
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
    if config ? limaHost && config.limaHost ? hostName && config.limaHost.hostName != null then
      config.limaHost.hostName
    else if config.networking.hostName != "" then
      config.networking.hostName
    else
      "nixos";
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

  loggerTagOrchestrate = "nixos.services.ssh-keys-enrichment.orchestrate";
  loggerTagEnrich = "nixos.services.ssh-keys-enrichment.enrichSSHKeysYaml";
  loggerTagSplit = "nixos.services.ssh-keys-enrichment.splitSSHKeysYaml";
  loggerTagExtract = "nixos.services.ssh-keys-enrichment.extractSSHKeys";
  sshEnrichKeysYamlScript = ndh.store.installBinScript "ssh-enrich-keys-yaml" (
    pkgs.replaceVars ../../.common.d/ssh-keys.d/ssh-enrich-keys-yaml.sh {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagEnrich;
    }
  );
  sshSplitKeysYamlScript = ndh.store.installBinScript "ssh-split-keys-yaml" (
    pkgs.replaceVars ../../.common.d/ssh-keys.d/ssh-split-keys-yaml.sh {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagSplit;
    }
  );
  sshEnrichSplitAndAuthorizeScript = ndh.store.installBinScript "ssh-enrich-split-and-authorize" (
    pkgs.replaceVars ../../.common.d/ssh-keys.d/ssh-enrich-split-runtime-keys.sh {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagOrchestrate;
    }
  );
  sshExtractKeysSplitExpFile = ndh.store.runCommand "ssh-extract-keys.split-exp.yq" { } ''
    install -m 0444 ${../../home-manager/ssh-key.d/ssh-extract-keys.split-exp.yq} "$out"
  '';
  sshExtractKeysScript = ndh.store.installBinScript "ssh-extract-keys" (
    pkgs.replaceVars ../../home-manager/ssh-key.d/ssh-extract-keys.sh {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagExtract;
      splitExpFile = sshExtractKeysSplitExpFile;
    }
  );
in
{
  config.systemd.services.${ndhSystemd.mkUnitName "ssh-keys-enrichment"} = {
    description = "Provision system linux-builder key from decrypted secrets (@codebase)";
    wantedBy = [ contributedTargetName ];
    requires = [
      keysTargetUnit
    ]
    ++ lib.optionals hasSopsInstallSecretsService [ "sops-install-secrets.service" ];
    after = [
      keysTargetUnit
    ]
    ++ lib.optionals hasLimaCloudInitService [ limaCloudInitServiceName ]
    ++ lib.optionals hasSopsInstallSecretsService [ "sops-install-secrets.service" ];
    before = [
      "sshd.service"
      hostkeyEnrollmentCheckServiceName
    ];
    path = with pkgs; [
      bash
      coreutils
      findutils
      gawk
      gnugrep
      gnused
      openssh
      inetutils
      yq-go
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
    };
    script = ''
      set -euo pipefail

      ${pkgs.bash}/bin/bash ${sshEnrichSplitAndAuthorizeScript}/bin/ssh-enrich-split-and-authorize \
        "${pkgs.bash}/bin/bash" \
        "${sshEnrichKeysYamlScript}/bin/ssh-enrich-keys-yaml" \
        "${sshSplitKeysYamlScript}/bin/ssh-split-keys-yaml" \
        "${sshKeyProfileName}" \
        "${hostIdent}" \
        "${decryptedSSHKeysYamlPath}" \
        "${generatedKeysYamlPath}" \
        "${inventoryHostsCsv}" \
        "${profileOwnerName}" \
        "${splitKeysDir}" \
        "${generatedSystemKeysYamlPath}" \
        "${generatedProfileKeysYamlPath}" \
        "${config.opensshPolicy.authorizedKeysDir}" \
        "${profileUserName}" \
        "${config.sshPaths.keyName}"

      # Materialize file-based SSH key artifacts expected by OpenSSH activation
      # and hostkey enrollment scripts in both bootstrap and full runtime modes.
      # Use the full enriched keyset so host/system key material is included.
      ${pkgs.bash}/bin/bash ${sshExtractKeysScript}/bin/ssh-extract-keys \
        "${generatedKeysYamlPath}" \
        "${config.sshPaths.secretsKeysDir}" \
        "${profileOwnerName}"
    '';
  };
}
