{
  config,
  pkgs,
  lib,
  ...
}:

let
  profile = config._module.specialArgs.profile;
  specialArgs = config._module.specialArgs;
  ndh = config._module.specialArgs.ndh;
  catalog = lib.attrByPath [ "catalog" ] { } ndh;
  profileName = profile.name;
  sshKeyProfileName =
    if profile ? sshKeyProfileName && profile.sshKeyProfileName != null then
      profile.sshKeyProfileName
    else
      profileName;
  userProfile = profile.user;
  userName = profile.user.name; # Use profile user name for tagging
  sshPaths = config.sshPaths;
  logger = config._module.specialArgs.ndh.logger.script;
  loggerTagPrepareGenerated = "home-manager.activationScripts.${userName}.prepareGeneratedSSHKeysYaml";
  loggerTagExtract = "home-manager.activationScripts.${userName}.extractSSHKeys";
  loggerTagAuthorized = "home-manager.activationScripts.${userName}.ensureAuthorizedKeys";
  perUserKeysDir = sshPaths.secretsKeysDir;
  authorityKeysDir = sshPaths.authoritySecretsDir;
  systemManagedSshKeysPipeline = pkgs.stdenv.isLinux || pkgs.stdenv.isDarwin;
  systemSplitProfileKeysYamlPath = "/run/secrets/nix-darwin-home/ssh-keys-split.d/profiles/${sshKeyProfileName}.yaml";
  alternateSystemSplitProfileKeysYamlPath = "${sshPaths.systemNamespaceDir}/ssh-keys-split.d/profiles/${sshKeyProfileName}.yaml";
  allowSystemSplitFallback = profileName == "work";
  runtimeSSHKeysYamlPath = sshPaths.runtimeSecretsKeysYaml;
  alternateRuntimeSSHKeysYamlPath = "${sshPaths.systemNamespaceDir}/ssh-keys.yaml";
  sourceProfileKeysYamlPath = "${./ssh.d/keys.yaml}";
  hostIdent =
    if
      profile ? host
      && profile.host ? hostAlias
      && profile.host.hostAlias != null
      && profile.host.hostAlias != ""
    then
      profile.host.hostAlias
    else if profile ? host && profile.host ? hostName && profile.host.hostName != null then
      profile.host.hostName
    else
      "darwin";
  catalogHostNames = if catalog ? hosts then builtins.attrNames catalog.hosts else [ ];
  hostsCatalogCsv = lib.concatStringsSep "," catalogHostNames;
  rootBringupProfileDir = "/nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bringup-runtime";
  # Effective YAML path consumed by ssh-add-keys/launchd.
  effectiveSSHKeysYamlPath = "${perUserKeysDir}.yaml";

  # Externalized KnownHostsCommand script sourced from repo (templated with keysDir)
  knownHostsScript = ndh.store.runCommand "ssh-ca-known-hosts" { } ''
    cp ${
      pkgs.replaceVars ./ssh.d/scripts/ca-known-hosts-command.sh {
        bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
        logger = logger;
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
    ../.common.d/ssh-paths.nix
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

      sshExtractKeysScriptSource = pkgs.replaceVars ./ssh-key.d/ssh-extract-keys.sh {
        bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
        logger = logger;
        loggerTag = loggerTagExtract;
        splitExpFile = sshExtractKeysSplitExpFile;
      };
      sshExtractKeysScript = ndh.store.installScript {
        name = "ssh-extract-keys.sh";
        source = sshExtractKeysScriptSource;
      };

      sshEnrichKeysYamlScriptSource = pkgs.replaceVars ../.common.d/ssh-keys.d/ssh-enrich-keys-yaml.sh {
        bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
        logger = logger;
        loggerTag = "home-manager.activationScripts.${userName}.enrichSSHKeysYaml";
      };
      sshEnrichKeysYamlScript = ndh.store.installScript {
        name = "ssh-enrich-keys-yaml.sh";
        source = sshEnrichKeysYamlScriptSource;
      };

      sshSplitKeysYamlScriptSource = pkgs.replaceVars ../.common.d/ssh-keys.d/ssh-split-keys-yaml.sh {
        bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
        logger = logger;
        loggerTag = "home-manager.activationScripts.${userName}.splitSSHKeysYaml";
      };
      sshSplitKeysYamlScript = ndh.store.installScript {
        name = "ssh-split-keys-yaml.sh";
        source = sshSplitKeysYamlScriptSource;
      };

      prepareGeneratedSSHKeysYamlScriptSource =
        pkgs.replaceVars ./ssh-key.d/ssh-prepare-generated-keys-yaml.sh
          {
            bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
            logger = logger;
            loggerTag = loggerTagPrepareGenerated;
            bash = "${pkgs.bash}/bin/bash";
            sops = "${pkgs.sops}/bin/sops";
            sshEnrichKeysYamlScript = sshEnrichKeysYamlScript;
            sshSplitKeysYamlScript = sshSplitKeysYamlScript;
            effectiveSSHKeysYamlPath = effectiveSSHKeysYamlPath;
            systemNamespaceDir = sshPaths.systemNamespaceDir;
            systemSplitProfileKeysYamlPath = systemSplitProfileKeysYamlPath;
            alternateSystemSplitProfileKeysYamlPath = alternateSystemSplitProfileKeysYamlPath;
            runtimeSSHKeysYamlPath = runtimeSSHKeysYamlPath;
            alternateRuntimeSSHKeysYamlPath = alternateRuntimeSSHKeysYamlPath;
            sshKeyProfileName = sshKeyProfileName;
            hostIdent = hostIdent;
            hostsCatalogCsv = hostsCatalogCsv;
            userName = userName;
            sourceProfileKeysYamlPath = sourceProfileKeysYamlPath;
          };
      prepareGeneratedSSHKeysYamlScript = ndh.store.installScript {
        name = "ssh-prepare-generated-keys-yaml.sh";
        source = prepareGeneratedSSHKeysYamlScriptSource;
      };

      ensureAuthorizedKeysScriptSource = pkgs.replaceVars ./ssh-key.d/ssh-ensure-authorized-keys.sh {
        bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
        logger = logger;
        loggerTag = loggerTagAuthorized;
      };
      ensureAuthorizedKeysScript = ndh.store.installScript {
        name = "ssh-ensure-authorized-keys.sh";
        source = ensureAuthorizedKeysScriptSource;
      };
    in
    {
      ensureRootBringupRuntimeProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${lib.optionalString allowSystemSplitFallback ''
                    if [[ ! -x "${rootBringupProfileDir}/bin/nix" || ! -x "${rootBringupProfileDir}/bin/bash" ]]; then
                      runtime_target_host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "<target-host>")"
                      echo "[ssh-keys][ERROR] required root runtime profile missing or incomplete: ${rootBringupProfileDir}" >&2
                      echo "[ssh-keys][ERROR] install/update it before running Home Manager activation" >&2
                      cat >&2 <<'EOF'
          [ssh-keys][HINT] On operator host (with nix-darwin-home checkout):

          holder_out="$(nix build --no-link --print-out-paths .#io-nxmatic-nix-darwin-home-bringup-runtime-profile-holder)"
          nix copy --no-check-sigs \
            --to 'ssh-ng://<target-host>?remote-program=/nix/var/nix/profiles/default/bin/nix-daemon' \
            "$holder_out"
          ssh -t <target-host> \
            "sudo /nix/var/nix/profiles/default/bin/nix profile add \
              --profile /nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bringup-runtime \
              $holder_out"
          EOF
                      echo "[ssh-keys][HINT] Replace <target-host> with: $runtime_target_host" >&2
                      exit 1
                    fi
        ''}
      '';

      # System-managed path (NixOS + Darwin): consume profile-specific generated YAML.
      prepareGeneratedSSHKeysYaml = lib.hm.dag.entryAfter [ "ensureRootBringupRuntimeProfile" ] ''
        ${lib.optionalString allowSystemSplitFallback ''
          ${pkgs.bash}/bin/bash ${prepareGeneratedSSHKeysYamlScript}
        ''}
        ${lib.optionalString (!allowSystemSplitFallback) ''
          if [[ -r "${systemSplitProfileKeysYamlPath}" ]]; then
            install -m 0700 -d "$(dirname "${effectiveSSHKeysYamlPath}")"
            install -m 0400 "${systemSplitProfileKeysYamlPath}" "${effectiveSSHKeysYamlPath}"
            chown "${userName}:$(id -gn "${userName}" 2>/dev/null || echo "${userName}")" "${effectiveSSHKeysYamlPath}" 2>/dev/null || true
          else
            echo "missing system-generated profile keys YAML: ${systemSplitProfileKeysYamlPath}" >&2
            echo "profile.name=${profileName} sshKeyProfileName=${sshKeyProfileName}" >&2
            exit 1
          fi
        ''}
      '';

      extractSSHKeys = lib.hm.dag.entryAfter [ "prepareGeneratedSSHKeysYaml" ] ''
        ${pkgs.bash}/bin/bash ${sshExtractKeysScript} "${effectiveSSHKeysYamlPath}" "${perUserKeysDir}" "${userName}"
      '';

      # Ensure mutable authorized_keys exists (symlink-free) with strict perms
      ensureAuthorizedKeys = lib.hm.dag.entryAfter [ "extractSSHKeys" ] ''
        ${pkgs.bash}/bin/bash ${ensureAuthorizedKeysScript}
      '';
    };

  programs.ssh.extraConfig = ''
    KnownHostsCommand ${knownHostsScript}
    EnableSSHKeysign yes
  '';
}
