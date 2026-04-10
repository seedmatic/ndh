{
  config,
  pkgs,
  lib,
  catalog,
  ...
}:
let
  profileName = if config ? profile && config.profile ? name then config.profile.name else "committed";
  sshKeyProfileName =
    if config ? profile && config.profile ? sshKeyProfileName && config.profile.sshKeyProfileName != null then
      config.profile.sshKeyProfileName
    else
      profileName;
  hostIdent =
    if config ? profile && config.profile ? host && config.profile.host ? hostAlias && config.profile.host.hostAlias != null && config.profile.host.hostAlias != "" then
      config.profile.host.hostAlias
    else if config ? profile && config.profile ? host && config.profile.host ? hostName && config.profile.host.hostName != null then
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

  hostsCatalog =
    let
      entries = builtins.readDir ../../hosts;
      hostDirs = lib.filterAttrs (
        name: type: type == "directory" && builtins.pathExists (../../hosts + "/${name}/flake.nix")
      ) entries;
    in
    lib.attrNames hostDirs;
  hostsCatalogCsv = lib.concatStringsSep "," hostsCatalog;

  catalogUsers = if catalog ? users then catalog.users else { };
  profileOwnerName =
    if builtins.hasAttr profileName catalogUsers && catalogUsers.${profileName} ? name && catalogUsers.${profileName}.name != null then
      catalogUsers.${profileName}.name
    else
      profileUserName;

  logger = config.nixBashLogger.script;
  loggerTagEnrich = "darwin.activationScripts.ssh-keys-enrichment.enrichSSHKeysYaml";
  sshEnrichKeysYamlScriptSource = pkgs.replaceVars ../.common.d/ssh-keys.d/ssh-enrich-keys-yaml.sh {
    bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
    logger = logger;
    loggerTag = loggerTagEnrich;
  };
  sshEnrichKeysYamlScript = pkgs.runCommand "ndh-ssh-enrich-keys-yaml-darwin.sh" { } ''
    install -m 0555 ${sshEnrichKeysYamlScriptSource} "$out"
  '';
in
{
  config.system.activationScripts.preActivation.text = lib.mkAfter ''
    set -euo pipefail

    if [[ ! -r "${decryptedSSHKeysYamlPath}" ]]; then
      echo "[ssh-keys-enrichment] missing decrypted SSH keys YAML: ${decryptedSSHKeysYamlPath}" >&2
      exit 1
    fi

    split_dir="${splitKeysDir}"
    profiles_dir="$split_dir/profiles"
    install -d -m 0755 "$split_dir" "$profiles_dir"

    ${pkgs.bash}/bin/bash ${sshEnrichKeysYamlScript} \
      "${sshKeyProfileName}" \
      "${hostIdent}" \
      "${decryptedSSHKeysYamlPath}" \
      "${generatedKeysYamlPath}" \
      "${hostsCatalogCsv}" \
      "${profileOwnerName}"

    # System split: keep host/system-signing material.
    ${pkgs.yq-go}/bin/yq eval -o=yaml '
      .keys |= with_entries(
        select(
          ((.value.usage // []) | any(. == "ssh-authority" or . == "ssh-host" or . == "host-signing"))
        )
      )
    ' "${generatedKeysYamlPath}" > "${generatedSystemKeysYamlPath}"
    install -m 0400 "${generatedSystemKeysYamlPath}" "${generatedSystemKeysYamlPath}.tmp"
    mv "${generatedSystemKeysYamlPath}.tmp" "${generatedSystemKeysYamlPath}"
    chown root:wheel "${generatedSystemKeysYamlPath}" 2>/dev/null || chown root:root "${generatedSystemKeysYamlPath}" || true

    # User split: keep user signing material (and default non-system keys).
    ${pkgs.yq-go}/bin/yq eval -o=yaml '
      .keys |= with_entries(
        select(
          ((.value.usage // []) as $u | ($u | any(. == "ssh-authority" or . == "ssh-host" or . == "host-signing")) | not)
        )
      )
    ' "${generatedKeysYamlPath}" > "${generatedProfileKeysYamlPath}"
    install -m 0440 "${generatedProfileKeysYamlPath}" "${generatedProfileKeysYamlPath}.tmp"
    mv "${generatedProfileKeysYamlPath}.tmp" "${generatedProfileKeysYamlPath}"
    chown "${profileOwnerName}:staff" "${generatedProfileKeysYamlPath}" 2>/dev/null || chown "${profileOwnerName}:wheel" "${generatedProfileKeysYamlPath}" 2>/dev/null || true

    echo "[ssh-keys-enrichment] generated runtime keys YAML: ${generatedKeysYamlPath}"
    echo "[ssh-keys-enrichment] split system keys YAML: ${generatedSystemKeysYamlPath}"
    echo "[ssh-keys-enrichment] split profile keys YAML: ${generatedProfileKeysYamlPath}"
  '';
}