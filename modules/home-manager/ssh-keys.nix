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

  # Command to filter and sign keys based on profile and host
  # Resolve a stable host identifier; hostAlias is optional by design (@codebase)
  hostIdent =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;

  yamlHostKeys =
    pkgs.runCommand "ssh-signed-keys.yaml"
      {
        # Provide every binary referenced by ssh-generate-keys-yaml.sh: bash, yq, ssh-keygen, sed, grep, awk, coreutils.
        buildInputs = [
          pkgs.bash # bash
          pkgs.coreutils-full # env, cut, mktemp, etc.
          pkgs.hostname # hostname
          pkgs.gawk # awk (robust text processing)
          pkgs.gnused # sed
          pkgs.gnugrep # grep -oE
          pkgs.openssh # ssh-keygen
          pkgs.yq-go # yq
        ];
      }
      ''
        bash ${./ssh-generate-keys-yaml.sh} "${profileName}" "${hostIdent}" "${./ssh.d/keys.yaml}" "$out"

        # Basic sanity: produced file must start with 'keys:' (or be empty if profile has no keys)
        if [ -s "$out" ] && ! head -n1 "$out" | grep -q '^keys:'; then
          echo "ssh-keys generation failed: unexpected output (missing keys: header)" >&2
          sed -n '1,200p' "$out" >&2 || true
          exit 1
        fi
      '';

  # Script to extract keys from keys.yaml
  # Full set (used for internal scripts like KnownHostsCommand)
  keysDir =
    pkgs.runCommand "${userName}::ssh-host-keys.d"
      {
        buildInputs = [
          pkgs.bash
          pkgs.coreutils-full # mkdir, mv, cut
          pkgs.yq-go # yq
          pkgs.gnused # sed (if needed later)
          pkgs.gnugrep # grep (if pattern matching added later)
          pkgs.gawk # awk (robust text processing)
          pkgs.gettext # envsubst
        ];
      }
      ''
        ${pkgs.bash}/bin/bash ${./ssh-extract-keys.sh} "${yamlHostKeys}" "$out"
      '';

  # User-only keys: exclude ssh-authority keys (system CA keys live in /etc/ssh/keys.d)
  userKeysYaml =
    pkgs.runCommand "${userName}::ssh-user-keys.yaml"
      {
        buildInputs = [ pkgs.yq-go ];
      }
      ''
        yq eval '(.keys | with_entries(select((.value.usage // []) | contains(["ssh-authority"]) | not))) as $k | {"keys": $k}' \
          "${yamlHostKeys}" > "$out"
      '';

  userKeysDir =
    pkgs.runCommand "${userName}::ssh-user-keys.d"
      {
        buildInputs = [
          pkgs.bash
          pkgs.coreutils-full
          pkgs.yq-go
          pkgs.gnused
          pkgs.gnugrep
          pkgs.gawk
          pkgs.gettext
        ];
      }
      ''
        ${pkgs.bash}/bin/bash ${./ssh-extract-keys.sh} "${userKeysYaml}" "$out"
      '';

  # Externalized KnownHostsCommand script sourced from repo (templated with keysDir)
  knownHostsScript =
    let
      scriptTemplate = builtins.readFile ./ssh.d/scripts/ca-known-hosts-command.sh;
      # Replace placeholder @CA_DIR@ with actual keysDir path (derivation output)
      # keysDir is a derivation; coerce to its store path string before replacement
      scriptProcessed =
        builtins.replaceStrings [ "@CA_DIR@" ] [ (builtins.toString keysDir) ]
          scriptTemplate;
    in
    pkgs.writeScript "ssh-ca-known-hosts" scriptProcessed;

in
{
  imports = [ ./ssh-add-keys.nix ];

  ssh-add-keys = {
    enable = true;
    keyFile = yamlHostKeys;
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
          in
          !(base == "keys.yaml" || base == ".gitattributes" || base == "authorized_keys");
      }
    );
    recursive = true;
  };

  home.file.".ssh/keys.yaml" = {
    source = yamlHostKeys;
  };

  # Deploy keys directly to ~/.ssh/keys.d/ with proper permissions (skip .local/state)
  # Externalized activation scripts: keep content in the store and execute via bash
  home.activation =
    let
      deploySSHKeysScript = pkgs.replaceVars ./ssh-keys.d/deploy-ssh-keys.sh {
        rsync = "${pkgs.rsync}/bin/rsync";
        keysDir = userKeysDir;
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
