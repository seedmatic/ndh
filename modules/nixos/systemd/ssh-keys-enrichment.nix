{
  config,
  pkgs,
  lib,
  ndh,
  ndhSystemd,
  worktreePath,
  ...
}:
let
  ndhContext = ndh.context;
  ndhCommon = (worktreePath.of "modules/.common.d");
  ndhHm = (worktreePath.of "modules/home-manager");
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
  enrichedKeysDir = "/run/ndh/ssh-keys.d";
  generatedKeysYamlPath = "${enrichedKeysDir}/keys.generated.yaml";
  generatedSystemKeysYamlPath = "${enrichedKeysDir}/system.yaml";
  authorizedPrincipalsInputPath = "${config.opensshPolicy.canonicalCommandDir}/authorized-principals-command.yaml";
  profileKeysYamlPathFor = profile: "${enrichedKeysDir}/profiles/${profile}.yaml";

  hasUserProfile = builtins.elem "user" profileNames;

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
    ssh-enrich-split-and-authorize =
      pkgs.replaceVars "${ndhCommon}/ssh-keys.d/ssh-enrich-split-runtime-keys.sh"
        {
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
      # step-cli signs tls-server x509 leaves when a key declares
      # `cert_usage: [tls-server]`; benign overhead when no such key is
      # present (shelled out only on demand).
      step-cli
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
    };
    script = ''
      set -euo pipefail

      # Pre-create the split output directory tree so that enrichment/split
      # scripts can always write their outputs even on first boot (mirrors the
      # explicit install -d in ssh-enrich-split-runtime-keys.sh).
      install -d -m 0755 "${enrichedKeysDir}" "${enrichedKeysDir}/profiles"

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

      # Pre-extract principals for AuthorizedPrincipalsCommand into a
      # non-secret input file.  The file contains only public principal
      # names (e.g. "rdp-host", "linux-builder") — no keys, no secrets —
      # so it is world-readable (mode 0644).  Restricting it to the
      # `_sshd` group (the previous policy) silently broke cert auth:
      # sshd's default AuthorizedPrincipalsCommandUser is `nobody`,
      # `nobody` is not in `_sshd`, the command's `[[ ! -r $INPUT_FILE ]]`
      # branch fired, it emitted only `$USER_NAME` (i.e. "root"), the
      # cert's principal (`rdp-host`) did not match, and sshd logged
      # "ED25519-CERT key is not allowed" with no further diagnostic.
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
      rm -f "$principals_input_tmp"

      # 3. Materialize extract artifacts into sshPaths.systemKeysDir
      #    (root-owned). The system-scope pass always runs — on bringup it
      #    covers nix-store / linux-builder; on full runtime it covers every
      #    key/cert that sshd or nix-daemon needs at boot. Passing the same
      #    dir for userOutputDir + systemPrivateOutputDir means every
      #    artifact (privates, pubs, authority pubs, certs) lands in one
      #    well-named place instead of a second scratch tree.
      #
      #    Feed generatedSystemKeysYamlPath (system-profile filtered) so
      #    keys outside the system profile don't spill their pubs here.
      ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-extract-keys \
        "${generatedSystemKeysYamlPath}" \
        "${config.sshPaths.systemKeysDir}" \
        root \
        "${config.sshPaths.systemKeysDir}"

      ${lib.optionalString hasUserProfile ''
        # User-scope pass: populate sshPaths.secretsKeysDir for HM consumers.
        # Skipped on bringup (profile.names = [ "bringup" ]) — no HM user
        # consumer and catalog.user.name need not exist as an OS account.
        #
        # Deliberately NOT passing sshPaths.systemKeysDir as the 4th arg
        # (systemPrivateOutputDir).  A previous revision did, which made
        # the user pass wipe + re-populate the system-owned tree as a
        # side effect; the user pass's full-yaml input included keys the
        # system pass had already extracted, so the user pass clobbered
        # the system dir's cert files and left the system tree with only
        # privates + cross-tree cert symlinks pointing into the user
        # home.  Omitting the 4th arg keeps the user pass in its own
        # lane: it only writes sshPaths.secretsKeysDir and never touches
        # sshPaths.systemKeysDir.
        ${pkgs.bash}/bin/bash ${sshKeysEnrichmentTools}/bin/ssh-extract-keys \
          "${generatedKeysYamlPath}" \
          "${config.sshPaths.secretsKeysDir}" \
          "${profileOwnerName}"
      ''}

      # 4. Build the aggregate TrustedUserCAKeys file in place — every
      #    activation, so stale CAs cannot linger.
      : > "${config.sshPaths.systemKeysDir}/trusted-user-ca.pub"
      for ca in "${config.sshPaths.systemKeysDir}"/*-ca.pub; do
        [ -f "$ca" ] || continue
        case "$(basename "$ca")" in
          trusted-user-ca.pub) continue ;;
        esac
        cat "$ca" >> "${config.sshPaths.systemKeysDir}/trusted-user-ca.pub"
        printf "\n" >> "${config.sshPaths.systemKeysDir}/trusted-user-ca.pub"
      done
      chmod 644 "${config.sshPaths.systemKeysDir}/trusted-user-ca.pub"
    '';
  };
}
