{
  config,
  pkgs,
  lib,
  ...
}:

let
  # Debug function that both traces and returns its input
  debugTrace = x: builtins.traceVerbose "Debug: profile = ${builtins.toJSON x}" x;

  profile = config._module.specialArgs.profile;

  profileName = profile.name;
  hostProfile = profile.host;
  userProfile = profile.user;
  userName = userProfile.name; # Use profile-based name (nxmatic) instead of description
  userDescription = userProfile.description;
  userHome = userProfile.home;

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

  # Script to extract host keys and CA public key from keys.yaml
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
  home.activation.deploySSHKeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run install -d -m 700 ~/.ssh/keys.d
    run ${pkgs.rsync}/bin/rsync -avL \
      --chmod=u+w,go-r \
      --chown=$(id -un):$(id -gn) \
      ${keysDir}/ ~/.ssh/keys.d/ || true
  '';

  # Ensure mutable authorized_keys exists (symlink-free) with strict perms
  home.activation.ensureAuthorizedKeys = lib.hm.dag.entryAfter [ "deploySSHKeys" ] ''
    run install -d -m 700 ~/.ssh
    if [ -L ~/.ssh/authorized_keys ]; then
      run rm -f ~/.ssh/authorized_keys
    fi
    if [ ! -f ~/.ssh/authorized_keys ]; then
      run install -m 600 /dev/null ~/.ssh/authorized_keys
    else
      run chmod 600 ~/.ssh/authorized_keys
    fi
  '';

  programs.ssh.extraConfig = ''
    KnownHostsCommand ${knownHostsScript}
    EnableSSHKeysign yes
  '';
}
