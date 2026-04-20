{
  config,
  pkgs,
  lib,
  catalog,
  inventory,
  ...
}:
let
  keysTargetUnit = "keys.target";
  hasSopsInstallSecretsService = builtins.hasAttr "sops-install-secrets" config.systemd.services;
  hasLimaCloudInitService = builtins.hasAttr "io-nxmatic-nix-darwin-home-lima-cloud-init" config.systemd.services;
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

  logger = config.nixBashLogger.script;
  loggerTagOrchestrate = "nixos.services.ssh-keys-enrichment.orchestrate";
  loggerTagEnrich = "nixos.services.ssh-keys-enrichment.enrichSSHKeysYaml";
  loggerTagSplit = "nixos.services.ssh-keys-enrichment.splitSSHKeysYaml";
  loggerTagExtract = "nixos.services.ssh-keys-enrichment.extractSSHKeys";
  sshEnrichKeysYamlScriptSource =
    pkgs.replaceVars ../../.common.d/ssh-keys.d/ssh-enrich-keys-yaml.sh
      {
        bashTrampoline = "${../../.common.d/shell.d/nix-bash-trampoline.sh}";
        logger = logger;
        loggerTag = loggerTagEnrich;
      };
  sshEnrichKeysYamlScript = pkgs.runCommand "ndh-ssh-enrich-keys-yaml-systemd.sh" { } ''
    install -m 0555 ${sshEnrichKeysYamlScriptSource} "$out"
  '';
  sshSplitKeysYamlScriptSource = pkgs.replaceVars ../../.common.d/ssh-keys.d/ssh-split-keys-yaml.sh {
    bashTrampoline = "${../../.common.d/shell.d/nix-bash-trampoline.sh}";
    logger = logger;
    loggerTag = loggerTagSplit;
  };
  sshSplitKeysYamlScript = pkgs.runCommand "ndh-ssh-split-keys-yaml-systemd.sh" { } ''
    install -m 0555 ${sshSplitKeysYamlScriptSource} "$out"
  '';
  sshEnrichSplitAndAuthorizeScriptSource =
    pkgs.replaceVars ../../.common.d/ssh-keys.d/ssh-enrich-split-runtime-keys.sh
      {
        bashTrampoline = "${../../.common.d/shell.d/nix-bash-trampoline.sh}";
        logger = logger;
        loggerTag = loggerTagOrchestrate;
      };
  sshEnrichSplitAndAuthorizeScript =
    pkgs.runCommand "ndh-ssh-enrich-split-and-authorize-linux-builder-systemd.sh" { }
      ''
        install -m 0555 ${sshEnrichSplitAndAuthorizeScriptSource} "$out"
      '';
  sshExtractKeysSplitExpFile = pkgs.runCommand "ndh-ssh-extract-keys.split-exp.yq" { } ''
    install -m 0444 ${../../home-manager/ssh-key.d/ssh-extract-keys.split-exp.yq} "$out"
  '';
  sshExtractKeysScriptSource =
    pkgs.replaceVars ../../home-manager/ssh-key.d/ssh-extract-keys.sh {
      bashTrampoline = "${../../.common.d/shell.d/nix-bash-trampoline.sh}";
      logger = logger;
      loggerTag = loggerTagExtract;
      splitExpFile = sshExtractKeysSplitExpFile;
    };
  sshExtractKeysScript = pkgs.runCommand "ndh-ssh-extract-keys-systemd.sh" { } ''
    install -m 0555 ${sshExtractKeysScriptSource} "$out"
  '';
in
{
  config.systemd.services.io-nxmatic-nix-darwin-home-ssh-keys-enrichment = {
    description = "Provision system linux-builder key from decrypted secrets (@codebase)";
    wantedBy = [ "io-nxmatic-nix-darwin-home-contributed.target" ];
    requires = [
      keysTargetUnit
    ]
    ++ lib.optionals hasSopsInstallSecretsService [ "sops-install-secrets.service" ];
    after = [
      keysTargetUnit
    ]
    ++ lib.optionals hasLimaCloudInitService [ "io-nxmatic-nix-darwin-home-lima-cloud-init.service" ]
    ++ lib.optionals hasSopsInstallSecretsService [ "sops-install-secrets.service" ];
    before = [
      "sshd.service"
      "io-nxmatic-nix-darwin-home-hostkey-enrollment-check.service"
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

      ${pkgs.bash}/bin/bash ${sshEnrichSplitAndAuthorizeScript} \
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
        "${generatedProfileKeysYamlPath}" \
        "${config.opensshPolicy.authorizedKeysDir}" \
        "${profileUserName}" \
        "${config.sshPaths.keyName}"

      # Materialize file-based SSH key artifacts expected by OpenSSH activation
      # and hostkey enrollment scripts in both bootstrap and full runtime modes.
      # Use the full enriched keyset so host/system key material is included.
      ${pkgs.bash}/bin/bash ${sshExtractKeysScript} \
        "${generatedKeysYamlPath}" \
        "${config.sshPaths.secretsKeysDir}" \
        "${profileOwnerName}"
    '';
  };
}
