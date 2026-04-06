{
  config,
  pkgs,
  lib,
  ...
}:

let
  profile = config._module.specialArgs.profile;
  profileName = profile.name;
  hostProfile = profile.host;
  userProfile = profile.user;
  userName = profile.user.name; # Use profile user name for tagging
  userDescription = userProfile.description;
  userHome = userProfile.home;
  logger = config._module.specialArgs.logger.script;
  activationTagGenerate = "home-manager.activationScripts.${userName}.generateSSHKeysYaml";
  activationTagExtract = "home-manager.activationScripts.${userName}.extractSSHKeys";
  activationTagAuthorized = "home-manager.activationScripts.${userName}.ensureAuthorizedKeys";
  sourceSSHKeysYamlPathOverride = lib.attrByPath [
    "_module"
    "specialArgs"
    "sshKeysYamlPath"
  ] null config;
  sshPaths = config.sshPaths;
  # Source YAML path (SOPS-decrypted profile YAML), used as input to generation.
  sourceSSHKeysYamlPath =
    if sourceSSHKeysYamlPathOverride != null then
      sourceSSHKeysYamlPathOverride
    else
      sshPaths.runtimeSecretsKeysYaml;
  perUserKeysDir = sshPaths.secretsKeysDir;
  authorityKeysDir = sshPaths.authoritySecretsDir;
  # Effective YAML path consumed by ssh-add-keys/launchd.
  effectiveSSHKeysYamlPath = "${perUserKeysDir}.yaml";

  # Command to filter and sign keys based on profile and host
  # Resolve a stable host identifier; hostAlias is optional by design (@codebase)
  hostIdent =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;

  hostsCatalog =
    let
      entries = builtins.readDir ../../hosts;
      hostDirs = lib.filterAttrs (
        name: type: type == "directory" && builtins.pathExists (../../hosts + "/${name}/flake.nix")
      ) entries;
    in
    lib.attrNames hostDirs;
  hostsCatalogCsv = lib.concatStringsSep "," hostsCatalog;

  # Externalized KnownHostsCommand script sourced from repo (templated with keysDir)
  knownHostsScript =
    pkgs.runCommand "ssh-ca-known-hosts" { } ''
      cp ${pkgs.replaceVars ./ssh.d/scripts/ca-known-hosts-command.sh {
        bashTrampoline = "${../common/shell.d/nix-bash-trampoline.sh}";
        logger = logger;
        caDir = authorityKeysDir;
      }} "$out"
      chmod +x "$out"
    '';

in
{
  imports = [
    ./ssh-add-keys.nix
    ../common/ssh-paths.nix
  ];

  ssh-add-keys = {
    enable = true;
    keyFile = effectiveSSHKeysYamlPath;
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

      sshGenerateKeysYamlScript = pkgs.replaceVars ./ssh-key.d/ssh-generate-keys-yaml.sh {
        bashTrampoline = "${../common/shell.d/nix-bash-trampoline.sh}";
        yq = "${pkgs.yq-go}/bin/yq";
        mktemp = "${pkgs.coreutils-full}/bin/mktemp";
        sed = "${pkgs.gnused}/bin/sed";
        hostname = "${pkgs.hostname}/bin/hostname";
        sshKeygen = "${pkgs.openssh}/bin/ssh-keygen";
        logger = logger;
        activationTag = activationTagGenerate;
      };

      sshExtractKeysScript = pkgs.replaceVars ./ssh-key.d/ssh-extract-keys.sh {
        bashTrampoline = "${../common/shell.d/nix-bash-trampoline.sh}";
        awk = "${pkgs.gawk}/bin/awk";
        ssh-keygen = "${pkgs.openssh}/bin/ssh-keygen";
        yq = "${pkgs.yq-go}/bin/yq";
        logger = logger;
        activationTag = activationTagExtract;
      };

      ensureAuthorizedKeysScript = pkgs.replaceVars ./ssh-key.d/ssh-ensure-authorized-keys.sh {
        bashTrampoline = "${../common/shell.d/nix-bash-trampoline.sh}";
        logger = logger;
        activationTag = activationTagAuthorized;
      };
    in
    {
      # Generate the YAML of keys to deploy based on the main keys.yaml and the current host/profile
      generateSSHKeysYaml = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${pkgs.bash}/bin/bash ${sshGenerateKeysYamlScript} "${profileName}" "$(${pkgs.hostname}/bin/hostname -s)" "${sourceSSHKeysYamlPath}" "${effectiveSSHKeysYamlPath}" "${hostsCatalogCsv}"
      '';

      # Deploy keys to the filesystem with proper permissions based on the generated YAML
      extractSSHKeys = lib.hm.dag.entryAfter [ "generateSSHKeysYaml" ] ''
        ${pkgs.bash}/bin/bash ${sshExtractKeysScript} "${effectiveSSHKeysYamlPath}" "${perUserKeysDir}"
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
