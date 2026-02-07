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
  hostKeysDir = "${userHome}/.ssh/keys.d";
  hostKeyPrivateFile = "${hostKeysDir}/host";
  hostKeyPublicCert = "${hostKeysDir}/host-mammoth-skate-host-cert.pub";
  caPublicKeyFile = "${config.opensshPolicy.keysDir}/trusted-user-ca.pub";
  principalsScriptStore = pkgs.writeText "ssh-authorized-principals-command.sh" (
    builtins.readFile ../common/ssh/authorized-principals-command.sh
  );
  groupKeysScriptStore = pkgs.replaceVars ../common/ssh/ssh-group-authorized-keys.sh {
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
              host:
                principals:
    ${formatPrincipals allPrincipals}
            work:
              host:
                principals:
    ${formatPrincipals allPrincipals}
  '';

  sshKeysYamlStore = pkgs.writeText "ssh-keys.yaml" sshKeysYamlText;

  # System CA keys derivation (public CA keys only)
  caKeysYaml = pkgs.runCommand "ssh-ca-keys.yaml"
    {
      buildInputs = [ pkgs.bash pkgs.coreutils-full pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.openssh pkgs.yq-go pkgs.hostname ];
    }
    ''
      bash ${../home-manager/ssh-generate-keys-yaml.sh} "${profileName}" "${hostAlias}" "${../home-manager/ssh.d/keys.yaml}" "$out"
      yq eval '(.keys | with_entries(select((.value.usage // []) | contains(["ssh-authority"])))) as $k | {"keys": $k}' -i "$out"
      # Drop any private material for CA keys (public CA only)
      yq eval '(.keys | with_entries(.value.private = null)) as $k | {"keys": $k}' -i "$out"
    '';

  caKeysDir = pkgs.runCommand "ssh-ca-keys.d"
    {
      buildInputs = [ pkgs.bash pkgs.coreutils-full pkgs.yq-go pkgs.gnused pkgs.gnugrep pkgs.gawk pkgs.gettext ];
    }
    ''
      ${pkgs.bash}/bin/bash ${../home-manager/ssh-extract-keys.sh} "${caKeysYaml}" "$out"
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
      bash ${opensshActivationScript}
      # Install system CA public keys into /etc/ssh/keys.d (single system location)
      install -d -m 755 "${config.opensshPolicy.keysDir}"
      ${pkgs.rsync}/bin/rsync -av --chmod=u+rw,go=r "${caKeysDir}/" "${config.opensshPolicy.keysDir}/" || true
      : > "${config.opensshPolicy.keysDir}/trusted-user-ca.pub"
      for ca in "${config.opensshPolicy.keysDir}/"*-ca.pub; do
        [ -f "$ca" ] || continue        [ "$(basename "$ca")" = "trusted-user-ca.pub" ] && continue        cat "$ca" >> "${config.opensshPolicy.keysDir}/trusted-user-ca.pub"
        printf "\n" >> "${config.opensshPolicy.keysDir}/trusted-user-ca.pub"
      done
      chmod 644 "${config.opensshPolicy.keysDir}/trusted-user-ca.pub"
    '';

  };
}
