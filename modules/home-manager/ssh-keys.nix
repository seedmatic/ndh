{
  config,
  pkgs,
  lib,
  paths,
  ...
}:

let
  ndhCommon = (paths.at "modules/.common.d");
  profile = config._module.specialArgs.profile;
  specialArgs = config._module.specialArgs;
  ndh = config._module.specialArgs.ndh;
  ndhContext = if ndh ? context then ndh.context else null;
  nixBashTrampoline =
    if ndhContext != null && ndhContext ? nixBashTrampoline then
      "${ndhContext.nixBashTrampoline}"
    else
      "${paths.at "modules/.common.d/shell.d/nix-bash-trampoline.sh"}";
  userProfile = profile.user;
  userName = profile.user.name; # Use profile user name for tagging
  sshPaths = config.sshPaths;
  loggerTagExtract = "home-manager.activationScripts.${userName}.extractSSHKeys";
  loggerTagAuthorized = "home-manager.activationScripts.${userName}.ensureAuthorizedKeys";
  perUserKeysDir = sshPaths.secretsKeysDir;
  authorityKeysDir = sshPaths.authoritySecretsDir;
  systemManagedSshKeysPipeline = pkgs.stdenv.isLinux || pkgs.stdenv.isDarwin;
  # HM is user-scope by construction → consume the `user.yaml` slice of
  # the enrichment split regardless of what other profiles the host
  # participates in. The enrichment service (modules/darwin/ssh-keys-
  # enrichment.nix + modules/nixos/systemd/ssh-keys-enrichment.nix)
  # emits this path when profile.names includes "user".
  systemSplitProfileKeysYamlPath = "/run/ndh/ssh-keys.d/profiles/user.yaml";
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
    (paths.at "modules/.common.d/ssh-paths.nix")
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

  # Deploy keys to canonical per-user runtime secrets directories with proper permissions.
  #
  # On Darwin, the prepare/extract/ensure pipeline runs from
  # modules/darwin/ssh-keys-enrichment.nix as a nix-darwin system
  # postActivation step so ordering against sops-install-secrets is explicit.
  # We leave these entries empty on Darwin to avoid double-materialization.
  #
  # On NixOS the dedicated systemd units (ssh-keys-enrichment + ssh-extract-keys)
  # handle both steps; HM only needs to run its own user-context extract here
  # to land keys under the user home.
  home.activation = lib.mkIf pkgs.stdenv.isLinux (
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
      # System-managed path: consume profile-specific generated YAML.
      prepareGeneratedSSHKeysYaml = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        if [[ -r "${systemSplitProfileKeysYamlPath}" ]]; then
          install -m 0700 -d "$(dirname "${effectiveSSHKeysYamlPath}")"
          install -m 0400 "${systemSplitProfileKeysYamlPath}" "${effectiveSSHKeysYamlPath}"
          chown "${userName}:$(id -gn "${userName}" 2>/dev/null || echo "${userName}")" "${effectiveSSHKeysYamlPath}" 2>/dev/null || true
        else
          echo "missing system-generated profile keys YAML: ${systemSplitProfileKeysYamlPath}" >&2
          echo "profile.names=${toString profile.names}" >&2
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
    }
  );

  programs.ssh.extraConfig = ''
    KnownHostsCommand ${knownHostsScript}
    EnableSSHKeysign yes
  '';
}
