{
  config,
  pkgs,
  lib,
  catalog,
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
  splitKeysDir = "/run/secrets/nix-darwin-home/ssh-keys-split.d";
  generatedKeysYamlPath = "${splitKeysDir}/keys.generated.yaml";
  generatedSystemKeysYamlPath = "${splitKeysDir}/system.yaml";
  generatedProfileKeysYamlPath = "${splitKeysDir}/profiles/${sshKeyProfileName}.yaml";

  hostsCatalog =
    let
      entries = builtins.readDir ../../../hosts;
      hostDirs = lib.filterAttrs (
        name: type: type == "directory" && builtins.pathExists (../../../hosts + "/${name}/flake.nix")
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
  loggerTagEnrich = "nixos.services.ssh-keys-enrichment.enrichSSHKeysYaml";
  sshEnrichKeysYamlScriptSource = pkgs.replaceVars ../../.common.d/ssh-keys.d/ssh-enrich-keys-yaml.sh {
    bashTrampoline = "${../../.common.d/shell.d/nix-bash-trampoline.sh}";
    logger = logger;
    loggerTag = loggerTagEnrich;
  };
  sshEnrichKeysYamlScript = pkgs.runCommand "ndh-ssh-enrich-keys-yaml-systemd.sh" { } ''
    install -m 0555 ${sshEnrichKeysYamlScriptSource} "$out"
  '';
in
{
  config.systemd.services.io-nxmatic-nix-darwin-home-ssh-keys-enrichment = {
    description = "Provision system linux-builder key from decrypted secrets (@codebase)";
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
      yq eval -o=yaml '
        .keys |= with_entries(
          select(
            ((.value.usage // []) | any(. == "ssh-authority" or . == "ssh-host" or . == "host-signing"))
          )
        )
      ' "${generatedKeysYamlPath}" > "${generatedSystemKeysYamlPath}"
      install -m 0400 "${generatedSystemKeysYamlPath}" "${generatedSystemKeysYamlPath}.tmp"
      mv "${generatedSystemKeysYamlPath}.tmp" "${generatedSystemKeysYamlPath}"
      chown root:root "${generatedSystemKeysYamlPath}"

      # User split: keep user signing material (and default non-system keys).
      yq eval -o=yaml '
        .keys |= with_entries(
          select(
            ((.value.usage // []) as $u | ($u | any(. == "ssh-authority" or . == "ssh-host" or . == "host-signing")) | not)
          )
        )
      ' "${generatedKeysYamlPath}" > "${generatedProfileKeysYamlPath}"
      install -m 0440 "${generatedProfileKeysYamlPath}" "${generatedProfileKeysYamlPath}.tmp"
      mv "${generatedProfileKeysYamlPath}.tmp" "${generatedProfileKeysYamlPath}"
      chown "${profileOwnerName}:${profileOwnerName}" "${generatedProfileKeysYamlPath}" || chown "${profileOwnerName}:users" "${generatedProfileKeysYamlPath}" || true

      key_type="$(yq -r '.keys."linux-builder".public // "" | split(" ") | .[0] // ""' "${generatedKeysYamlPath}")"
      key_public="$(yq -r '.keys."linux-builder".public // "" | split(" ") | .[1] // ""' "${generatedKeysYamlPath}")"
      key_comment="$(yq -r '.keys."linux-builder".public // "" | split(" ") | .[2] // ""' "${generatedKeysYamlPath}")"

      if [[ -z "$key_type" ]]; then
        key_type="ssh-ed25519"
      fi
      if [[ -z "$key_comment" ]]; then
        key_comment="linux-builder@mammoth-skate"
      fi

      if [[ -z "$key_public" ]]; then
        echo "[ssh-keys-enrichment][ERROR] missing linux-builder public key in ${generatedKeysYamlPath}" >&2
        exit 1
      fi

      auth_dir="${config.opensshPolicy.authorizedKeysDir}"
      auth_file="$auth_dir/${profileUserName}"
      install -d -m 0755 "$auth_dir"

      touch "$auth_file"
      chmod 0644 "$auth_file"
      chown root:root "$auth_file"

      line="$key_type $key_public $key_comment"
      if ! grep -Fqx "$line" "$auth_file"; then
        printf '%s\n' "$line" >> "$auth_file"
      fi

      awk 'NF > 0' "$auth_file" | awk '!seen[$0]++' > "$auth_file.tmp"
      install -m 0644 "$auth_file.tmp" "$auth_file"
      chown root:root "$auth_file"
      rm -f "$auth_file.tmp"

      echo "[ssh-keys-enrichment] generated runtime keys YAML: ${generatedKeysYamlPath}"
      echo "[ssh-keys-enrichment] split system keys YAML: ${generatedSystemKeysYamlPath}"
      echo "[ssh-keys-enrichment] split profile keys YAML: ${generatedProfileKeysYamlPath}"
      echo "[ssh-keys-enrichment] ensured linux-builder key in $auth_file"
    '';
  };
}
