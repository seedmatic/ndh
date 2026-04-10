{
  config,
  pkgs,
  lib,
  ...
}:
let
  keysTargetUnit = "keys.target";
  hasSopsInstallSecretsService = builtins.hasAttr "sops-install-secrets" config.systemd.services;
  hasLimaCloudInitService = builtins.hasAttr "io-nxmatic-nix-darwin-home-lima-cloud-init" config.systemd.services;
  profileUserName =
    if config ? profile && config.profile ? user && config.profile.user ? name then config.profile.user.name else "root";
  profileName = if config ? profile && config.profile ? name then config.profile.name else "committed";
  sshKeyProfileName =
    if config ? profile && config.profile ? sshKeyProfileName && config.profile.sshKeyProfileName != null then
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
  effectiveSSHKeysYamlPath = "${config.sshPaths.secretsKeysDir}.yaml";

  hostsCatalog =
    let
      entries = builtins.readDir ../../../hosts;
      hostDirs = lib.filterAttrs (
        name: type: type == "directory" && builtins.pathExists (../../../hosts + "/${name}/flake.nix")
      ) entries;
    in
    lib.attrNames hostDirs;
  hostsCatalogCsv = lib.concatStringsSep "," hostsCatalog;

  logger = config.nixBashLogger.script;
  loggerTagGenerate = "nixos.services.ssh-keys-enrichment.generateSSHKeysYaml";
  loggerTagExtract = "nixos.services.ssh-keys-enrichment.extractSSHKeys";

  sshGenerateKeysYamlScriptSource = pkgs.replaceVars ../../home-manager/ssh-key.d/ssh-generate-keys-yaml.sh {
    bashTrampoline = "${../../.common.d/shell.d/nix-bash-trampoline.sh}";
    logger = logger;
    loggerTag = loggerTagGenerate;
  };
  sshGenerateKeysYamlScript = pkgs.runCommand "ndh-ssh-generate-keys-yaml-systemd.sh" { } ''
    install -m 0555 ${sshGenerateKeysYamlScriptSource} "$out"
  '';

  sshExtractKeysSplitExpFile = pkgs.runCommand "ndh-ssh-extract-keys-systemd.split-exp.yq" { } ''
    install -m 0444 ${../../home-manager/ssh-key.d/ssh-extract-keys.split-exp.yq} "$out"
  '';

  sshExtractKeysScriptSource = pkgs.replaceVars ../../home-manager/ssh-key.d/ssh-extract-keys.sh {
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
    description = "Enrich and materialize SSH keys from decrypted system secrets (@codebase)";
    wantedBy = [ "io-nxmatic-nix-darwin-home-contributed.target" ];
    requires = [ keysTargetUnit ] ++ lib.optionals hasSopsInstallSecretsService [ "sops-install-secrets.service" ];
    after =
      [ keysTargetUnit ]
      ++ lib.optionals hasLimaCloudInitService [ "io-nxmatic-nix-darwin-home-lima-cloud-init.service" ]
      ++ lib.optionals hasSopsInstallSecretsService [ "sops-install-secrets.service" ];
    before = [ "sshd.service" "io-nxmatic-nix-darwin-home-hostkey-enrollment-check.service" ];
    path = with pkgs; [
      bash
      coreutils
      findutils
      gawk
      gnugrep
      gnused
      openssh
      yq-go
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
    };
    script = ''
      set -euo pipefail

      if [[ ! -r "${decryptedSSHKeysYamlPath}" ]]; then
        echo "[ssh-keys-enrichment] missing decrypted SSH keys YAML: ${decryptedSSHKeysYamlPath}" >&2
        exit 1
      fi

      ${pkgs.bash}/bin/bash ${sshGenerateKeysYamlScript} \
        "${sshKeyProfileName}" \
        "${hostIdent}" \
        "${decryptedSSHKeysYamlPath}" \
        "${effectiveSSHKeysYamlPath}" \
        "${hostsCatalogCsv}" \
        "${profileUserName}"

      ${pkgs.bash}/bin/bash ${sshExtractKeysScript} \
        "${effectiveSSHKeysYamlPath}" \
        "${config.sshPaths.secretsKeysDir}" \
        "${profileUserName}"
    '';
  };
}
