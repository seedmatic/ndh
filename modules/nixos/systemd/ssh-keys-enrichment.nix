{
  config,
  pkgs,
  lib,
  ndh,
  ndhSystemd,
  self,
  ...
}:
let
  ndhContext = ndh.context;
  ndhCommon = "${self}/modules/.common.d";
  ndhHm = "${self}/modules/home-manager";
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
  # v2 profile membership (list). Bringup forces [ "bringup" ]; runtime
  # hosts default to [ "system" "user" ]. See modules/nixos/bringup-minimal-
  # system.nix for the bringup override.
  profileNames =
    if config ? profile && config.profile ? names && config.profile.names != [ ] then
      config.profile.names
    else
      [
        "system"
        "user"
      ];
  hostIdent =
    if config ? limaHost && config.limaHost ? hostName && config.limaHost.hostName != null then
      config.limaHost.hostName
    else if config.networking.hostName != "" then
      config.networking.hostName
    else
      "nixos";
  decryptedSSHKeysYamlPath = config.sshPaths.runtimeSecretsKeysYaml;
  # Outside the sops-install-secrets namespace so that unit's strict
  # directory-replacement sweep does not nuke our enrichment outputs.
  splitKeysDir = "/run/ndh/ssh-keys-split.d";
  generatedKeysYamlPath = "${splitKeysDir}/keys.generated.yaml";
  generatedSystemKeysYamlPath = "${splitKeysDir}/system.yaml";
  authorizedPrincipalsInputPath = "${config.opensshPolicy.canonicalCommandDir}/authorized-principals-command.yaml";
  profileKeysYamlPathFor = profile: "${splitKeysDir}/profiles/${profile}.yaml";

  inventoryHostNames = builtins.attrNames (inventory.hosts or { });
  inventoryHostsCsv = lib.concatStringsSep "," inventoryHostNames;

  # v2: single catalog user; profile name no longer drives OS user lookup.
  profileOwnerName =
    if catalog ? user && catalog.user ? name && catalog.user.name != null then
      catalog.user.name
    else
      profileUserName;

  loggerTagOrchestrate = "nixos.services.ssh-keys-enrichment.orchestrate";
  loggerTagEnrich = "nixos.services.ssh-keys-enrichment.enrichSSHKeysYaml";
  loggerTagSplit = "nixos.services.ssh-keys-enrichment.splitSSHKeysYaml";
  loggerTagExtract = "nixos.services.ssh-keys-enrichment.extractSSHKeys";

  sshExtractKeysSplitExpFile = ndh.store.runCommand "ssh-extract-keys.split-exp.yq" { } ''
    install -m 0444 "${ndhHm}/ssh-key.d/ssh-extract-keys.split-exp.yq" "$out"
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
    # ssh-extract-keys carries an extra @splitExpFile@ substitution but shares
    # the same activation pipeline + logger shape, so bundle it alongside.
    ssh-extract-keys = pkgs.replaceVars "${ndhHm}/ssh-key.d/ssh-extract-keys.sh" {
      nixBashTrampoline = nixBashTrampoline;
      loggerTag = loggerTagExtract;
      splitExpFile = sshExtractKeysSplitExpFile;
    };
  };
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

      # 1. Enrich the decrypted sops yaml into keys.generated.yaml.
      ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-enrich-keys-yaml \
        "${hostIdent}" \
        "${decryptedSSHKeysYamlPath}" \
        "${generatedKeysYamlPath}" \
        "${inventoryHostsCsv}" \
        "${profileOwnerName}"

      # 2. Split into per-profile yamls (one invocation per profile name
      #    in profile.names). Each run emits the same system.yaml
      #    (system-scope filter) plus one profiles/<name>.yaml (filter by
      #    that profile's membership).
      ${lib.concatMapStringsSep "\n" (p: ''
        ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-split-keys-yaml \
          "${generatedKeysYamlPath}" \
          "${generatedSystemKeysYamlPath}" \
          "${profileKeysYamlPathFor p}" \
          "${profileOwnerName}" \
          "${p}"
      '') profileNames}

      # Pre-extract principals for AuthorizedPrincipalsCommand into a dedicated
      # non-secret input file readable by sshd helper user (_sshd).
      install -d -m 0755 "$(dirname "${authorizedPrincipalsInputPath}")"
      principals_input_tmp="$(mktemp)"
      ${pkgs.yq-go}/bin/yq eval '
        {
          "principals": (
            [
              (
                .keys // {}
                | to_entries
                | .[]
                | .value.principals // []
                | select(tag == "!!seq")
                | .[]
              ),
              (
                .keys // {}
                | to_entries
                | .[]
                | .value.principals // {}
                | select(tag == "!!map")
                | keys
                | .[]
              )
            ]
            | flatten
            | map(select(. != null and . != ""))
            | sort
            | unique
          )
        }
      ' "${generatedKeysYamlPath}" > "$principals_input_tmp"
      install -m 0644 "$principals_input_tmp" "${authorizedPrincipalsInputPath}"
      for sshd_group in _sshd sshd; do
        if awk -F: -v g="$sshd_group" '$1 == g { found = 1 } END { exit !found }' /etc/group; then
          chgrp "$sshd_group" "${authorizedPrincipalsInputPath}" || true
          chmod 0640 "${authorizedPrincipalsInputPath}" || true
          break
        fi
      done
      rm -f "$principals_input_tmp"

      # 3. Materialize extract artifacts: the full enriched set drives
      #    both the per-user deploy (secretsKeysDir) and the system-scope
      #    drop to systemKeysDir (privates whose .profiles ∋ "system").
      ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-extract-keys \
        "${generatedKeysYamlPath}" \
        "${config.sshPaths.secretsKeysDir}" \
        "${profileOwnerName}" \
        "${config.sshPaths.systemKeysDir}"
    '';
  };
}
