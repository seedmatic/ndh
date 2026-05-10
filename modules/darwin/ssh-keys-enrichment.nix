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
  # Profile membership list (v2). Defaults to the runtime profile set
  # when unspecified; bringup-minimal-system forces [ "bringup" ].
  profileNames =
    if config ? profile && config.profile ? names && config.profile.names != [ ] then
      config.profile.names
    else
      [
        "system"
        "user"
      ];
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
  # Per-profile split outputs. One yaml per profile name this host
  # participates in. The legacy 4-arg ssh-split-keys-yaml signature still
  # expects a single profile path, so we invoke it once per entry below.
  profileKeysYamlPathFor = profile: "${splitKeysDir}/profiles/${profile}.yaml";

  inventoryHostNames = builtins.attrNames (inventory.hosts or { });
  inventoryHostsCsv = lib.concatStringsSep "," inventoryHostNames;

  # v2 has a single catalog user; profile name no longer drives the
  # OS user lookup.
  profileOwnerName =
    if catalog ? user && catalog.user ? name && catalog.user.name != null then
      catalog.user.name
    else
      profileUserName;

  loggerTagOrchestrate = "darwin.activationScripts.ssh-keys-enrichment.orchestrate";
  loggerTagEnrich = "darwin.activationScripts.ssh-keys-enrichment.enrichSSHKeysYaml";
  loggerTagSplit = "darwin.activationScripts.ssh-keys-enrichment.splitSSHKeysYaml";
  loggerTagExtractSystem = "darwin.activationScripts.ssh-keys-enrichment.extractSystemKeys";
  loggerTagExtractUser = "darwin.activationScripts.ssh-keys-enrichment.extractUserKeys";
  loggerTagEnsureAuthorizedKeys = "darwin.activationScripts.ssh-keys-enrichment.ensureAuthorizedKeys";

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
    # System-scope extract: ssh-host privates → sshPaths.systemKeysDir.
    ssh-extract-keys-system = pkgs.replaceVars "${self}/modules/home-manager/ssh-key.d/ssh-extract-keys.sh" {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagExtractSystem;
      splitExpFile = sshExtractKeysSplitExpFile;
    };
    # User-scope extract: everything else → ~<profileOwner>/.local/var/run/secrets/ssh-keys.
    ssh-extract-keys-user = pkgs.replaceVars "${self}/modules/home-manager/ssh-key.d/ssh-extract-keys.sh" {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagExtractUser;
      splitExpFile = sshExtractKeysSplitExpFile;
    };
    ssh-ensure-authorized-keys = pkgs.replaceVars "${self}/modules/home-manager/ssh-key.d/ssh-ensure-authorized-keys.sh" {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagEnsureAuthorizedKeys;
    };
  };

  # Scratch dir for the system-side extract pass: we only care about what
  # lands in systemKeysDir (4th arg below). User-scope keys are materialized
  # in a separate user-context step, so the system extract's userOutputDir
  # points at a root-owned throwaway.
  systemExtractScratchDir = "/var/lib/ndh/ssh-keys-extract-scratch";

  # Effective per-user yaml path (mirrors the path derived in
  # modules/home-manager/ssh-keys.nix) so we can prepare it from the
  # root-context before invoking the user-scope extractor.
  perUserSecretsKeysDir = config.sshPaths.secretsKeysDir;
  effectiveUserSSHKeysYamlPath = "${perUserSecretsKeysDir}.yaml";

  # The HM consumer (modules/home-manager/ssh-keys.nix) always reads the
  # "user" slice; other profiles (host/bringup) feed the system-scope
  # extract exclusively.
  hmProfileName = "user";
  hmProfileKeysYamlPath = profileKeysYamlPathFor hmProfileName;

  # Shell snippet that invokes ssh-split-keys-yaml once per profile name
  # the host participates in. Each call emits two files (system.yaml +
  # the per-profile yaml); we only care about the per-profile output
  # here, but the script insists on writing both. The system.yaml is
  # overwritten on every iteration — same content (all host-scope keys)
  # so harmless.
  splitAllProfilesSnippet = lib.concatMapStringsSep "\n\n" (p: ''
    ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-split-keys-yaml \
      ${lib.escapeShellArg generatedKeysYamlPath} \
      ${lib.escapeShellArg generatedSystemKeysYamlPath} \
      ${lib.escapeShellArg (profileKeysYamlPathFor p)} \
      ${lib.escapeShellArg profileOwnerName} \
      ${lib.escapeShellArg p}
  '') profileNames;
in
{
  # Split into two postActivation steps so ordering against sops-install-secrets
  # (which runs mid-postActivation in the nix-darwin activate script) is explicit:
  #   1. system-scope enrichment + extract → runs after sops via lib.mkOrder 1500
  #      (sops-install-secrets lands around mkOrder 1000 by default).
  #   2. user-scope extract + authorized_keys maintenance → runs after (1).
  config.system.activationScripts.postActivation.text = lib.mkOrder 1500 ''
    set -euo pipefail

    # Enrichment produces the full enriched yaml at generatedKeysYamlPath.
    # We then invoke split-keys-yaml once per profile in profile.names.
    ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-enrich-keys-yaml \
      ${lib.escapeShellArg hostIdent} \
      ${lib.escapeShellArg decryptedSSHKeysYamlPath} \
      ${lib.escapeShellArg generatedKeysYamlPath} \
      ${lib.escapeShellArg inventoryHostsCsv} \
      ${lib.escapeShellArg profileOwnerName}

    ${splitAllProfilesSnippet}

    # System-scope extract: ssh-host privates land in sshPaths.systemKeysDir.
    # /var/lib/ndh/ssh-keys-extract-scratch catches user/authority duplicates
    # we do not need in this pass.
    install -d -m 0700 ${lib.escapeShellArg systemExtractScratchDir}
    ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-extract-keys-system \
      ${lib.escapeShellArg generatedKeysYamlPath} \
      ${lib.escapeShellArg systemExtractScratchDir} \
      root \
      ${lib.escapeShellArg config.sshPaths.systemKeysDir}

    # Install the user-scope per-profile yaml where HM's extractor expects it.
    # install runs as root so we chown to the profile owner afterwards.
    ${lib.optionalString (builtins.elem hmProfileName profileNames) ''
      install -m 0700 -d "$(dirname ${lib.escapeShellArg effectiveUserSSHKeysYamlPath})"
      install -m 0400 ${lib.escapeShellArg hmProfileKeysYamlPath} ${lib.escapeShellArg effectiveUserSSHKeysYamlPath}
      chown ${lib.escapeShellArg profileOwnerName} ${lib.escapeShellArg effectiveUserSSHKeysYamlPath} || true

      # User-scope extract: populate ~<user>/.local/var/run/secrets/ssh-keys.
      # `launchctl asuser ... sudo -u <user>` is the nix-darwin-standard way to
      # run a step in the user's context during activation.
      launchctl asuser "$(id -u ${lib.escapeShellArg profileOwnerName})" \
        sudo -H -u ${lib.escapeShellArg profileOwnerName} \
          ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-extract-keys-user \
            ${lib.escapeShellArg effectiveUserSSHKeysYamlPath} \
            ${lib.escapeShellArg perUserSecretsKeysDir} \
            ${lib.escapeShellArg profileOwnerName}

      launchctl asuser "$(id -u ${lib.escapeShellArg profileOwnerName})" \
        sudo -H -u ${lib.escapeShellArg profileOwnerName} \
          ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-ensure-authorized-keys
    ''}
  '';
}
