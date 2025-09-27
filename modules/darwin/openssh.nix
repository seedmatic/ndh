{ self, config, pkgs, lib, ... }:
let
  profile = config.profile;
  userHome = profile.user.home;
  hostKeysDir = "${userHome}/.ssh/keys.d";
  hostKeyPrivateFile = "${hostKeysDir}/host";
  hostKeyPublicCert = "${hostKeysDir}/host-mammoth_skate-host-cert.pub";
  caPublicKeyFile = "${hostKeysDir}/mammoth_skate-ca.pub";
  # We first embed the script content; later in activation we copy it to /etc/ssh so sshd references a mutable path
    principalsScriptStore = pkgs.writeText "ssh-authorized-principals-command.sh" (builtins.readFile ../common/ssh/authorized-principals-command.sh);
    groupKeysScriptStore = pkgs.writeText "ssh-group-authorized-keys-command.sh" (builtins.readFile ../common/ssh/ssh-group-authorized-keys.sh);
in {
  imports = [ ../common/openssh-policy.nix ];

  opensshPolicy = {
    enable = true;
    passwordAuthentication = false;
    permitRootLogin = "no";
    trustedCAPath = caPublicKeyFile;
    principalsFilePath = "%h/.ssh/authorized_principals";
    principalsCommandSource = principalsScriptStore;
    principalsCommandUser = "_sshd";
    groupDirectory = "/etc/ssh/group_authorized_keys.d";
    groupKeysCommandSource = groupKeysScriptStore;
    groupCommandUser = "_sshd";
    authorizedKeysFiles = [ "%h/.ssh/authorized_keys" "/etc/ssh/group_authorized_keys.d/%u" ];
    hostKeyPaths = [ hostKeyPrivateFile ];
    hostCertificatePath = hostKeyPublicCert;
    extraSettings = { };
  };

  # Ensure tools used by principals/group commands are available (yq for principals parsing)
  # Include openssh so that `ssh` and related client tools resolve to the Nix
  # provided version (rather than the macOS /usr/bin defaults). This ensures
  # consistent feature set and version across hosts and allows quicker
  # upgrading / pinning. Without this, `command -v ssh` points to /usr/bin/ssh.
  environment.systemPackages = with pkgs; [ rsync yq-go openssh ];

  # nix-darwin lacks a generic `settings` attr like NixOS; render policy into extraConfig.
  # Darwin module name is `services.sshd` (not `services.openssh`). We map our policy
  # settings selectively to the exposed options; the rest go into extraConfig.
  # Fallback approach: darwin module lacks the NixOS-style settings interface in this environment.
  # We therefore render a complete sshd_config from policy and install it via /etc/ssh/sshd_config.
  # If the upstream module gains `settings` support later, this block can be simplified.
  services.openssh.enable = true;

  environment.etc."ssh/sshd_config".text = let
    boolToYesNo = v: if v then "yes" else "no";
    renderValue = v: if builtins.isBool v then boolToYesNo v else builtins.toString v;
    policyLines = lib.mapAttrsToList (k: v: "${k} ${renderValue v}") config.opensshPolicy.settings;
    hostKeyLines = map (p: "HostKey ${p}") config.opensshPolicy.hostKeys;
    # Only add HostCertificate if not already produced via settings (avoid duplicates)
    certAlready = lib.any (l: lib.hasPrefix "HostCertificate " l) policyLines;
    certLine = if (!certAlready && config.opensshPolicy.settings ? HostCertificate)
      then ["HostCertificate ${config.opensshPolicy.settings.HostCertificate}"] else [];
    all = hostKeyLines ++ certLine ++ policyLines;
  in lib.concatStringsSep "\n" all + "\n";

  system.activationScripts.postActivation.text = ''
    # Install builder keys for nix daemon (root) access (Darwin)
    install -d -m 755 /etc/nix
    if [ -f "${hostKeysDir}/linux_builder" ]; then
      install -m 600 -o root -g wheel "${hostKeysDir}/linux_builder" /etc/nix/builder_ed25519_profile
    fi
    if [ -f "${hostKeysDir}/linux_builder.pub" ]; then
      install -m 644 -o root -g wheel "${hostKeysDir}/linux_builder.pub" /etc/nix/builder_ed25519_profile.pub
    fi

    # Install group-based AuthorizedKeysCommand script (root-owned, executable, not writable by others)
    install -d -m 755 /etc/ssh
    # Install group keys command via canonical naming
    install -m 555 ${groupKeysScriptStore} /etc/ssh/${config.opensshPolicy.canonicalGroupKeysCommandName}
    if [ ! -e /etc/ssh/ssh-group-authorized-keys ]; then
      ln -s ${config.opensshPolicy.canonicalGroupKeysCommandName} /etc/ssh/ssh-group-authorized-keys
    fi

    # Install principals command at runtime path (avoid nix store reference in sshd_config)
    install -m 555 ${principalsScriptStore} /etc/ssh/${config.opensshPolicy.canonicalPrincipalsCommandName}
    if [ ! -e /etc/ssh/authorized-principals-command ]; then
      ln -s ${config.opensshPolicy.canonicalPrincipalsCommandName} /etc/ssh/authorized-principals-command
    fi

    # Consolidate legacy duplicates: replace real files with symlinks pointing to new canonical names when content matches
    consolidate() {
      legacy="$1"; canonical="$2"; linkTarget="$3"
      if [ -f "$legacy" ] && [ -f "$canonical" ] && [ ! -L "$legacy" ]; then
        if cmp -s "$legacy" "$canonical"; then
          rm -f "$legacy"
          ln -s "$linkTarget" "$legacy"
        fi
      fi
    }
    consolidate /etc/ssh/authorized-principals-command \
      /etc/ssh/${config.opensshPolicy.canonicalPrincipalsCommandName} \
      ${config.opensshPolicy.canonicalPrincipalsCommandName}
    consolidate /etc/ssh/ssh-group-authorized-keys \
      /etc/ssh/${config.opensshPolicy.canonicalGroupKeysCommandName} \
      ${config.opensshPolicy.canonicalGroupKeysCommandName}

    # Remove any stale darwin-specific variant if identical to canonical
    if [ -f /etc/ssh/ssh-group-authorized-keys-darwin ] && \
       cmp -s /etc/ssh/ssh-group-authorized-keys-darwin /etc/ssh/${config.opensshPolicy.canonicalGroupKeysCommandName}; then
      rm -f /etc/ssh/ssh-group-authorized-keys-darwin
    fi

    # Migration: if legacy /etc/ssh/authorized_keys.d (previous group dir) exists and our new dir absent
    if [ -d /etc/ssh/authorized_keys.d ] && [ ! -d /etc/ssh/group_authorized_keys.d ]; then
      echo "[ssh] Migrating legacy /etc/ssh/authorized_keys.d -> /etc/ssh/group_authorized_keys.d" >&2
      install -d -m 755 /etc/ssh/group_authorized_keys.d
      # Copy only non-user-specific files (heuristic: all files) preserving perms
      for f in /etc/ssh/authorized_keys.d/*; do
        [ -f "$f" ] || continue
        cp -p "$f" /etc/ssh/group_authorized_keys.d/ || true
      done
      # Do not remove automatically; instruct user once migration confirmed.
      echo "[ssh] Review and remove /etc/ssh/authorized_keys.d if no longer needed." >&2
    fi

    # Ensure new group keys directory exists
    install -d -m 755 /etc/ssh/group_authorized_keys.d
  '';
}
