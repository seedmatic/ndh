{
  config,
  pkgs,
  lib,
  self,
  ...
}:

let
  ndhCommon = "${self}/modules/.common.d";
  profile = config._module.specialArgs.profile;
  specialArgs = config._module.specialArgs;
  ndh = config._module.specialArgs.ndh;
  ndhContext = if ndh ? context then ndh.context else null;
  nixBashTrampoline =
    if ndhContext != null && ndhContext ? nixBashTrampoline then
      "${ndhContext.nixBashTrampoline}"
    else
      "${self}/modules/.common.d/shell.d/nix-bash-trampoline.sh";
  profileName = profile.name;
  userProfile = profile.user;
  userName = profile.user.name; # Use profile user name for tagging
  sshPaths = config.sshPaths;
  loggerTagExtract = "home-manager.activationScripts.${userName}.extractSSHKeys";
  loggerTagAuthorized = "home-manager.activationScripts.${userName}.ensureAuthorizedKeys";
  perUserKeysDir = sshPaths.secretsKeysDir;
  authorityKeysDir = sshPaths.authoritySecretsDir;
  systemManagedSshKeysPipeline = pkgs.stdenv.isLinux || pkgs.stdenv.isDarwin;
  # Match the splitKeysDir used by the platform enrichment services:
  # modules/darwin/ssh-keys-enrichment.nix and
  # modules/nixos/systemd/ssh-keys-enrichment.nix.
  systemSplitProfileKeysYamlPath = "/run/ndh/ssh-keys-split.d/profiles/${profileName}.yaml";
  # Effective YAML path consumed by ssh-add-keys/launchd.
  effectiveSSHKeysYamlPath = "${perUserKeysDir}.yaml";

  # Externalized KnownHostsCommand script sourced from repo (templated with keysDir)
  knownHostsScript = ndh.store.runCommand "ssh-ca-known-hosts" { } ''
    cp ${
      pkgs.replaceVars ./ssh.d/scripts/ca-known-hosts-command.sh {
        nixBashTrampoline = nixBashTrampoline;
        caDir = authorityKeysDir;
      }
    } "$out"
    chmod +x "$out"
  '';

in
{
  assertions = [
    {
      assertion = systemManagedSshKeysPipeline;
      message = ''
        ssh-keys system pipeline requires Linux or Darwin platform.
        This module now expects system-generated split profile YAML as canonical input.
      '';
    }
  ];

  imports = [
    ./ssh-add-keys.nix
    "${ndhCommon}/ssh-paths.nix"
  ];

  ssh-add-keys = {
    enable = true;
    keyFile = effectiveSSHKeysYamlPath;
    allowedKeyNames = [
      sshPaths.keyName
      "linux-builder"
    ];
  };

  home.file.".ssh" = {
    source = pkgs.lib.mkForce (
      pkgs.lib.cleanSourceWith {
        src = ./ssh.d;
        # Exclude dynamically generated or unwanted files from deployment into ~/.ssh
        # We skip:
        #  - keys.yaml (it is generated separately as yamlHostKeys)
        #  - .gitattributes (repo hygiene only, not needed in target)
        #  - authorized_keys (we will manage / append dynamically at runtime)
        filter =
          path: type:
          let
            base = builtins.baseNameOf path;
            includeLimaConfig = pkgs.stdenv.isDarwin;
          in
          !(
            base == "keys.yaml"
            || base == ".gitattributes"
            || base == "authorized_keys"
            || (!includeLimaConfig && base == "lima.conf")
          );
      }
    );
    recursive = true;
  };

  # Deploy keys to canonical per-user runtime secrets directories with proper permissions
  # Externalized activation scripts: keep content in the store and execute via bash
  home.activation =
    let
      sshExtractKeysSplitExpFile = ndh.store.installScript {
        name = "ssh-extract-keys.split-exp.yq";
        source = ./ssh-key.d/ssh-extract-keys.split-exp.yq;
        mode = "0444";
      };

      sshKeyLifecycleTools = ndh.store.installBinScriptBundle "ssh-key-lifecycle-tools" {
        ssh-extract-keys = pkgs.replaceVars ./ssh-key.d/ssh-extract-keys.sh {
          nixBashTrampoline = nixBashTrampoline;
          loggerTag = loggerTagExtract;
          splitExpFile = sshExtractKeysSplitExpFile;
        };
        ssh-ensure-authorized-keys = pkgs.replaceVars ./ssh-key.d/ssh-ensure-authorized-keys.sh {
          nixBashTrampoline = nixBashTrampoline;
          loggerTag = loggerTagAuthorized;
        };
      };
    in
    {
      # System-managed path (NixOS + Darwin): consume profile-specific generated YAML.
      prepareGeneratedSSHKeysYaml = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        if [[ -r "${systemSplitProfileKeysYamlPath}" ]]; then
          install -m 0700 -d "$(dirname "${effectiveSSHKeysYamlPath}")"
          install -m 0400 "${systemSplitProfileKeysYamlPath}" "${effectiveSSHKeysYamlPath}"
          chown "${userName}:$(id -gn "${userName}" 2>/dev/null || echo "${userName}")" "${effectiveSSHKeysYamlPath}" 2>/dev/null || true
        else
          echo "missing system-generated profile keys YAML: ${systemSplitProfileKeysYamlPath}" >&2
          echo "profile.name=${profileName}" >&2
          exit 1
        fi
      '';

      extractSSHKeys = lib.hm.dag.entryAfter [ "prepareGeneratedSSHKeysYaml" ] ''
        ${pkgs.bash}/bin/bash ${sshKeyLifecycleTools}/bin/ssh-extract-keys "${effectiveSSHKeysYamlPath}" "${perUserKeysDir}" "${userName}"
      '';

      # Ensure mutable authorized_keys exists (symlink-free) with strict perms
      ensureAuthorizedKeys = lib.hm.dag.entryAfter [ "extractSSHKeys" ] ''
        ${pkgs.bash}/bin/bash ${sshKeyLifecycleTools}/bin/ssh-ensure-authorized-keys
      '';
    };

  programs.ssh.extraConfig = ''
    KnownHostsCommand ${knownHostsScript}
    EnableSSHKeysign yes
  '';
}
