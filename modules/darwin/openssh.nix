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
      : "Install builder keys for nix daemon (root) access (Darwin)"
      install -d -m 755 /etc/nix
      if [ -f "${hostKeysDir}/linux_builder" ]; then
        install -m 600 -o root -g wheel "${hostKeysDir}/linux_builder" /etc/nix/builder_ed25519_profile
      fi
      if [ -f "${hostKeysDir}/linux_builder.pub" ]; then
        install -m 644 -o root -g wheel "${hostKeysDir}/linux_builder.pub" /etc/nix/builder_ed25519_profile.pub
      fi

      : "Install group-based AuthorizedKeysCommand script"
      install -d -m 755 /etc/ssh
      install -m 555 ${groupKeysScriptStore} /etc/ssh/${config.opensshPolicy.canonicalGroupKeysCommandName}
      install -m 555 ${principalsScriptStore} /etc/ssh/${config.opensshPolicy.canonicalPrincipalsCommandName}

      : "Ensure drop-in include directories exist"
      install -d -m 755 /etc/ssh/sshd_config.d
      install -d -m 755 /etc/ssh/ssh_config.d
    '';
  };
}
