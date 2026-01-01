{ self, config, pkgs, lib, ... }:
let
  profile = config.profile;
  userHome = profile.user.home;
  hostKeysDir = "${userHome}/.ssh/keys.d";
  hostKeyPrivateFile = "${hostKeysDir}/host";
  hostKeyPublicCert = "${hostKeysDir}/host-mammoth-skate-host-cert.pub";
  caPublicKeyFile = "${hostKeysDir}/mammoth-skate-ca.pub";
  principalsScriptStore = pkgs.writeText "ssh-authorized-principals-command.sh" (builtins.readFile ../common/ssh/authorized-principals-command.sh);
  groupKeysScriptStore = pkgs.writeText "ssh-group-authorized-keys-command.sh" (builtins.readFile ../common/ssh/ssh-group-authorized-keys.sh);
  inherit (lib) mkIf optionalString concatStringsSep;

  # Align builder key provisioning with linux-builder module: pull from keys.yaml
  keysJson = pkgs.runCommand "keys.json" { buildInputs = [ pkgs.yq-go ]; } ''
    yq -o=json '.' ${../home-manager/ssh.d/keys.yaml} > $out
  '';
  keys = builtins.fromJSON (builtins.readFile keysJson);
  currentProfile = profile.name;
  builderProfile = currentProfile;
  builderPrivKey = keys.profiles.${builderProfile}.linux-builder.private;
  builderPubKey = keys.profiles.${builderProfile}.linux-builder.public;
  builderPrivStore = pkgs.writeText "builder_ed25519" builderPrivKey;
  builderPubStore = pkgs.writeText "builder_ed25519.pub" builderPubKey;

  nixKeyDir = "/etc/nix/keys.d";
  nixKey = "${nixKeyDir}/builder_ed25519";
  nixKeyPub = "${nixKeyDir}/builder_ed25519.pub";

  # Derive principals based on profile and hostname
  # Server should accept all possible principals from any client
  # committed profile hosts: accept [committed, work, alcide]
  # work profile hosts: accept [committed, work, alcide] 
  hostAlias = if (profile.host ? hostAlias && profile.host.hostAlias != null) 
    then profile.host.hostAlias 
    else profile.host.hostName;
  profileName = profile.name;

  # All hosts should accept all profile principals to allow cross-host connections
  # This ensures bioskop (committed) can accept from alcide (work) and vice versa
  allPrincipals = [ "committed" "work" "alcide" "bioskop" ];
  
  # Format principals as YAML list with proper indentation (6 spaces for list items)
  formatPrincipals = principals: 
    concatStringsSep "\n" (map (p: "              - ${p}") principals);

  opensshActivationScript = pkgs.writeShellScript "openssh-activation.sh" ''
    set -euo pipefail
    LOG="/var/log/darwin-openssh-activation.log"
    {
      echo "[openssh] start $(date)"

      : "Install builder keys for nix daemon (root) access (Darwin)"
      install -d -m 755 /etc/nix
      install -d -m 700 ${nixKeyDir}

      install -m 600 -o root -g wheel ${builderPrivStore} ${nixKey}
      install -m 644 -o root -g wheel ${builderPubStore} ${nixKeyPub}

      : "Install group-based AuthorizedKeysCommand script"
      install -d -m 755 /etc/ssh
      install -m 555 ${groupKeysScriptStore} /etc/ssh/${config.opensshPolicy.canonicalGroupKeysCommandName}
      install -m 555 ${principalsScriptStore} /etc/ssh/${config.opensshPolicy.canonicalPrincipalsCommandName}

      : "Ensure drop-in include directories exist"
      install -d -m 755 /etc/ssh/sshd_config.d
      install -d -m 755 /etc/ssh/ssh_config.d

      echo "[openssh] end $(date)"
    } >>"$LOG" 2>&1
  '';

in {
  imports = [ ../common/openssh-policy.nix ];

  config = {
    # Server policy wiring
    opensshPolicy = {
      enable = true;
      trustedCAPath = caPublicKeyFile;
      principalsCommandSource = principalsScriptStore;
      principalsCommandUser = "_sshd";
      groupKeysCommandSource = groupKeysScriptStore;
      groupCommandUser = "_sshd";
      hostKeyPaths = [ hostKeyPrivateFile ];
      hostCertificatePath = hostKeyPublicCert;

      # Enable SSH client policy to generate guest stanzas system-wide
      client.enable = true;
    };

    # System packages
    environment.systemPackages = with pkgs; [ rsync yq-go openssh ];

    # Create keys.yaml for certificate principal validation
    # This is world-readable in /etc so _sshd can access it
    # All hosts accept all profile principals for cross-host connections
    environment.etc."ssh/keys.yaml".text = ''
      # Certificate principal validation for ${hostAlias} (${profileName} profile)
      # Managed by modules/darwin/openssh.nix - regenerated on darwin-rebuild
      # Accepts all profile principals to allow cross-host connections
      profiles:
        committed:
          host:
            principals:
${formatPrincipals allPrincipals}
        work:
          host:
            principals:
${formatPrincipals allPrincipals}
    '';

    # SSH daemon configuration
    environment.etc."ssh/sshd_config".text = let
      boolToYesNo = v: if v then "yes" else "no";
      renderValue = v: if builtins.isBool v then boolToYesNo v else builtins.toString v;
      policyLines = lib.mapAttrsToList (k: v: "${k} ${renderValue v}") config.opensshPolicy.settings;
      hostKeyLines = map (p: "HostKey ${p}") config.opensshPolicy.hostKeys;
      certAlready = lib.any (l: lib.hasPrefix "HostCertificate " l) policyLines;
      certLine = if (!certAlready && config.opensshPolicy.settings ? HostCertificate)
        then ["HostCertificate ${config.opensshPolicy.settings.HostCertificate}"] else [];
      includeLines = builtins.map (g: "Include ${g}") config.opensshPolicy.includeDaemonGlobs;
      all = hostKeyLines ++ certLine ++ policyLines ++ includeLines;
    in lib.concatStringsSep "\n" all + "\n";

    services.openssh.enable = true;

    system.activationScripts.postActivation.text = ''
      ${opensshActivationScript}
    '';
  };
}
