{
  self,
  config,
  pkgs,
  lib,
  ...
}:
let
  profile = config.profile;
  userHome = profile.user.home;
  userName = profile.user.name;
  sshPaths = config.sshPaths;
  hostKeysDir = sshPaths.systemSecretsDir;
  hostKeyPrivateFile = sshPaths.privKeyFile;
  hostKeyPublicCert = sshPaths.hostCertPublic;
  caPublicKeyFile = "${config.opensshPolicy.keysDir}/trusted-user-ca.pub";
  principalsScriptStore = pkgs.replaceVars ../common/ssh/authorized-principals-command.sh {
    bashBin = "${pkgs.bash}/bin/bash";
    yqBin = "${pkgs.yq-go}/bin/yq";
  };
  groupKeysScriptStore = pkgs.replaceVars ../common/ssh/ssh-group-authorized-keys.sh {
    bashBin = "${pkgs.bash}/bin/bash";
    authorizedKeysDir = config.opensshPolicy.authorizedKeysDir;
  };
  inherit (lib) mkIf optionalString concatStringsSep;

  # Derive principals based on profile and hostname
  # Server should accept all possible principals from any client
  # committed profile hosts: accept [committed, work, alcide]
  # work profile hosts: accept [committed, work, alcide]
  hostAlias =
    if (profile.host ? hostAlias && profile.host.hostAlias != null) then
      profile.host.hostAlias
    else
      profile.host.hostName;
  profileName = profile.name;

  # All hosts should accept all profile principals to allow cross-host connections
  # This ensures bioskop (committed) can accept from alcide (work) and vice versa
  allPrincipals = [
    "committed"
    "work"
    "alcide"
    "bioskop"
  ];

  # Format principals as YAML list with proper indentation (6 spaces for list items)
  formatPrincipals = principals: concatStringsSep "\n" (map (p: "              - ${p}") principals);

  sshKeysYamlText = ''
          # Certificate principal validation for ${hostAlias} (${profileName} profile)
          # Managed by modules/darwin/openssh.nix - regenerated on darwin-rebuild
          # Accepts all profile principals to allow cross-host connections
          profiles:
            committed:
              rdp-host:
                principals:
    ${formatPrincipals allPrincipals}
            work:
              rdp-host:
                principals:
    ${formatPrincipals allPrincipals}
  '';

  sshdConfigText =
    let
      boolToYesNo = v: if v then "yes" else "no";
      renderValue = v: if builtins.isBool v then boolToYesNo v else builtins.toString v;
      policyLines = lib.mapAttrsToList (k: v: "${k} ${renderValue v}") config.opensshPolicy.settings;
      hostKeyLines = map (p: "HostKey ${p}") config.opensshPolicy.hostKeys;
      certAlready = lib.any (l: lib.hasPrefix "HostCertificate " l) policyLines;
      certLine =
        if (!certAlready && config.opensshPolicy.settings ? HostCertificate) then
          [ "HostCertificate ${config.opensshPolicy.settings.HostCertificate}" ]
        else
          [ ];
      includeLines = builtins.map (g: "Include ${g}") config.opensshPolicy.includeDaemonGlobs;
      all = hostKeyLines ++ certLine ++ policyLines ++ includeLines;
    in
    lib.concatStringsSep "\n" all + "\n";

  sshdConfigStore = pkgs.writeText "sshd_config" sshdConfigText;

  opensshActivationScript = pkgs.replaceVars ./openssh.d/openssh-activation.sh {
    groupKeysScriptStore = groupKeysScriptStore;
    principalsScriptStore = principalsScriptStore;
    groupKeysCommand = config.opensshPolicy.canonicalGroupKeysCommandName;
    principalsCommand = config.opensshPolicy.canonicalPrincipalsCommandName;
    activationLogger = lib.attrByPath [
      "activation"
      "loggerScript"
    ] ../common/activation-logger.sh config;
  };

in
{
  imports = [
    ../common/openssh-policy.nix
    ../common/ssh-paths.nix
  ];

  config = {
    # Server policy wiring
    opensshPolicy = {
      enable = true;
      platformRendersAuthorizedKeysFile = lib.mkDefault true;
      setEnvPath = lib.mkDefault "/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin";
      nonInteractivePrimaryPath = lib.mkDefault "/run/current-system/sw/bin";
      trustedCAPath = caPublicKeyFile;
      principalsCommandSource = principalsScriptStore;
      principalsCommandUser = "_sshd";
      groupKeysCommandSource = groupKeysScriptStore;
      groupCommandUser = "_sshd";
      hostKeyPaths = [ hostKeyPrivateFile ];
      hostCertificatePath = hostKeyPublicCert;

      # Force IPv4 only for SSH server
      extraSettings = {
        AddressFamily = "inet";
      };

      # Enable SSH client policy to generate guest stanzas system-wide
      client.enable = true;
    };

    # System packages
    environment.systemPackages = with pkgs; [
      rsync
      yq-go
      openssh
    ];

    # Create keys.yaml for certificate principal validation
    # This is world-readable in /etc so _sshd can access it
    # All hosts accept all profile principals for cross-host connections
    environment.etc."ssh/keys.yaml".text = sshKeysYamlText;

    # SSH daemon configuration
    environment.etc."ssh/sshd_config".text = sshdConfigText;

    services.openssh.enable = true;

    # Ensure OpenSSH activation runs in the etc fragment (installs /etc/ssh helper scripts)
    system.activationScripts.etc.text = lib.mkAfter ''
      # Provision split SSH key directories.
      install -d -m 0755 "${sshPaths.perUserSecretsRoot}"
      install -d -m 0700 "${sshPaths.perUserSecretsDir}"
      install -d -m 0755 "${sshPaths.systemSecretsDir}"
      chown "${userName}" "${sshPaths.perUserSecretsDir}"
      chown "${userName}" "${sshPaths.systemSecretsDir}"

      bash ${opensshActivationScript}
      # Install system CA public keys from runtime user keys directory.
      install -d -m 755 "${config.opensshPolicy.keysDir}"
      for ca in "${hostKeysDir}"/*-ca.pub; do
        [ -f "$ca" ] || continue
        install -m 644 "$ca" "${config.opensshPolicy.keysDir}/$(basename "$ca")"
      done
      : > "${config.opensshPolicy.keysDir}/trusted-user-ca.pub"
      for ca in "${config.opensshPolicy.keysDir}/"*-ca.pub; do
        [ -f "$ca" ] || continue
        basename "$ca" | grep -q '^trusted-user-ca\.pub$' && continue
        cat "$ca" >> "${config.opensshPolicy.keysDir}/trusted-user-ca.pub"
        printf "\n" >> "${config.opensshPolicy.keysDir}/trusted-user-ca.pub"
      done
      chmod 644 "${config.opensshPolicy.keysDir}/trusted-user-ca.pub"
    '';

  };
}
