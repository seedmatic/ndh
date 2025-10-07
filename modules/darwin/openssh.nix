{ self, config, pkgs, lib, ... }:
let
  profile = config.profile;
  userHome = profile.user.home;
  hostKeysDir = "${userHome}/.ssh/keys.d";
  hostKeyPrivateFile = "${hostKeysDir}/host";
  hostKeyPublicCert = "${hostKeysDir}/host-mammoth-skate-host-cert.pub";
  caPublicKeyFile = "${hostKeysDir}/mammoth-skate-ca.pub";
  # We first embed the script content; later in activation we copy it to /etc/ssh so sshd references a mutable path
  principalsScriptStore = pkgs.writeText "ssh-authorized-principals-command.sh" (builtins.readFile ../common/ssh/authorized-principals-command.sh);
  groupKeysScriptStore = pkgs.writeText "ssh-group-authorized-keys-command.sh" (builtins.readFile ../common/ssh/ssh-group-authorized-keys.sh);
in {
  imports = [ ../common/openssh-policy.nix ];

  opensshPolicy = {
    enable = true;
    trustedCAPath = caPublicKeyFile;
    principalsCommandSource = principalsScriptStore;
    principalsCommandUser = "_sshd";
    groupKeysCommandSource = groupKeysScriptStore;
    groupCommandUser = "_sshd";
    hostKeyPaths = [ hostKeyPrivateFile ];
    hostCertificatePath = hostKeyPublicCert;
    # All other defaults (AuthorizedKeysFile, groupDirectory, SetEnv PATH, Include globs)
    # come from the shared openssh-policy. Override here only if Darwin really needs special values.
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
    includeLines = builtins.map (g: "Include ${g}") config.opensshPolicy.includeDaemonGlobs;
    all = hostKeyLines ++ certLine ++ policyLines ++ includeLines;
  in lib.concatStringsSep "\n" all + "\n";

  # Provide a minimal ssh client config that honors shared Include globs
  environment.etc."ssh/ssh_config".text = let
    includeLines = builtins.map (g: "Include ${g}") config.opensshPolicy.includeClientGlobs;
  in lib.concatStringsSep "\n" includeLines + "\n";

  system.activationScripts.postActivation.text = ''
    : "Install builder keys for nix daemon (root) access (Darwin)"
    install -d -m 755 /etc/nix
    if [ -f "${hostKeysDir}/linux_builder" ]; then
      install -m 600 -o root -g wheel "${hostKeysDir}/linux_builder" /etc/nix/builder_ed25519_profile
    fi
    if [ -f "${hostKeysDir}/linux_builder.pub" ]; then
      install -m 644 -o root -g wheel "${hostKeysDir}/linux_builder.pub" /etc/nix/builder_ed25519_profile.pub
    fi

    : "Install group-based AuthorizedKeysCommand script (root-owned, executable, not writable by others)"
    install -d -m 755 /etc/ssh
    : "Install group keys command via canonical naming"
    install -m 555 ${groupKeysScriptStore} /etc/ssh/${config.opensshPolicy.canonicalGroupKeysCommandName}

    : "Install principals command at runtime path (avoid nix store reference in sshd_config)"
    install -m 555 ${principalsScriptStore} /etc/ssh/${config.opensshPolicy.canonicalPrincipalsCommandName}

    : "Ensure shared group keys directory exists"
    install -d -m 755 ${config.opensshPolicy.groupDirectory}

    : "Ensure drop-in include directories exist"
    install -d -m 755 /etc/ssh/sshd_config.d
    install -d -m 755 /etc/ssh/ssh_config.d
  '';
}
