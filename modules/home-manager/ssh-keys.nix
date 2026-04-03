{
  config,
  pkgs,
  lib,
  ...
}:

let
  profile = config._module.specialArgs.profile;
  # Debug function that both traces and returns its input
  debugTrace = x: builtins.traceVerbose "Debug: profile = ${builtins.toJSON x}" x;

  profileName = profile.name;
  hostProfile = profile.host;
  userProfile = profile.user;
  userName = profile.user.name; # Use profile user name for tagging
  userDescription = userProfile.description;
  userHome = userProfile.home;
  activationLogger = config._module.specialArgs.activationLogger.script;
  activationTagDeploy = "home-manager.activationScripts.${userName}.deploySSHKeys";
  activationTagAuthorized = "home-manager.activationScripts.${userName}.ensureAuthorizedKeys";
  sshKeysYamlPath = lib.attrByPath [ "_module" "specialArgs" "sshKeysYamlPath" ] null config;
  canonicalRuntimeKeysYaml = "/run/secrets/nix-darwin-home/nxmatic-ssh-keys.yaml";
  keysStateDir = "${config.xdg.stateHome}/ssh-keys.d";

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
        name: type:
        type == "directory" && builtins.pathExists (../../hosts + "/${name}/flake.nix")
      ) entries;
    in
    lib.attrNames hostDirs;
  hostsCatalogCsv = lib.concatStringsSep "," hostsCatalog;

  # Externalized KnownHostsCommand script sourced from repo (templated with keysDir)
  knownHostsScript =
    let
      scriptTemplate = builtins.readFile ./ssh.d/scripts/ca-known-hosts-command.sh;
      # Resolve CA keys dynamically from XDG state runtime keys dir to avoid store-backed private material.
      scriptProcessed =
        builtins.replaceStrings [ "@CA_DIR@" ] [ keysStateDir ]
          scriptTemplate;
    in
    pkgs.writeScript "ssh-ca-known-hosts" scriptProcessed;

in
{
  imports = [ ./ssh-add-keys.nix ];

  ssh-add-keys = {
    enable = true;
    keyFile =
      if sshKeysYamlPath != null then
        sshKeysYamlPath
      else
        canonicalRuntimeKeysYaml;
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

  # Deploy keys directly to $XDG_STATE_HOME/ssh-keys.d with proper permissions
  # Externalized activation scripts: keep content in the store and execute via bash
  home.activation =
    let
      sshExtractKeysScript = pkgs.replaceVars ./ssh-extract-keys.sh {
        awk = "${pkgs.gawk}/bin/awk";
        yq = "${pkgs.yq-go}/bin/yq";
      };

      deploySSHKeysScript = pkgs.replaceVars ./ssh-keys.d/deploy-ssh-keys.sh {
        awk = "${pkgs.gawk}/bin/awk";
        bash = "${pkgs.bash}/bin/bash";
        mktemp = "${pkgs.coreutils-full}/bin/mktemp";
        rsync = "${pkgs.rsync}/bin/rsync";
        yq = "${pkgs.yq-go}/bin/yq";
        sshExtractKeys = "${sshExtractKeysScript}";
        profileName = profileName;
        keysYaml =
          if sshKeysYamlPath != null then
            sshKeysYamlPath
          else
            canonicalRuntimeKeysYaml;
        activationLogger = activationLogger;
        activationTag = activationTagDeploy;
      };

      ensureAuthorizedKeysScript = pkgs.replaceVars ./ssh-keys.d/ensure-authorized-keys.sh {
        activationLogger = activationLogger;
        activationTag = activationTagAuthorized;
      };
    in
    {
      deploySSHKeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${pkgs.bash}/bin/bash ${deploySSHKeysScript}
      '';

      # Ensure mutable authorized_keys exists (symlink-free) with strict perms
      ensureAuthorizedKeys = lib.hm.dag.entryAfter [ "deploySSHKeys" ] ''
        ${pkgs.bash}/bin/bash ${ensureAuthorizedKeysScript}
      '';
    };

  programs.ssh.extraConfig = ''
    KnownHostsCommand ${knownHostsScript}
    EnableSSHKeysign yes
  '';
}
