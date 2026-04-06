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
  loggerScript = lib.attrByPath [
    "activation"
    "loggerScript"
  ] ../common/shell.d/logger.sh config;
  hostKeysDir = sshPaths.authoritySecretsDir;
  clientKeyName = builtins.baseNameOf sshPaths.privKeyFile;
  hostKeyPrivateFile = sshPaths.privKeyFile;
  hostKeyPublicCert = sshPaths.hostCertPublic;
  caPublicKeyFile = "${config.opensshPolicy.keysDir}/trusted-user-ca.pub";
  principalsScriptStore = pkgs.replaceVars ../common/ssh/authorized-principals-command.sh {
    bashTrampoline = "${../common/shell.d/nix-bash-trampoline.sh}";
    logger = loggerScript;
    scriptPath = config.opensshPolicy.setEnvPath;
  };
  groupKeysScriptStore = pkgs.replaceVars ../common/ssh/ssh-group-authorized-keys.sh {
    bashTrampoline = "${../common/shell.d/nix-bash-trampoline.sh}";
    logger = loggerScript;
    scriptPath = config.opensshPolicy.setEnvPath;
    authorizedKeysDir = config.opensshPolicy.authorizedKeysDir;
  };
  inherit (lib) mkIf optionalString concatStringsSep;

  # Derive principals based on profile and hostname
  # Server should accept all possible principals from any client
  # committed profile hosts: accept [committed, work, nikopol]
  # work profile hosts: accept [committed, work, nikopol]
  hostAlias =
    if (profile.host ? hostAlias && profile.host.hostAlias != null) then
      profile.host.hostAlias
    else
      profile.host.hostName;
  profileName = profile.name;

  # All hosts should accept all profile principals to allow cross-host connections
  # This ensures bioskop (committed) can accept from nikopol (work) and vice versa
  allPrincipals = [
    "committed"
    "work"
    "nikopol"
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
              ${clientKeyName}:
                principals:
    ${formatPrincipals allPrincipals}
            work:
              ${clientKeyName}:
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
    logger = loggerScript;
  };

  opensshPostActivationScript = pkgs.replaceVars ./openssh.d/post-activation.sh {
    hostKeysDir = hostKeysDir;
    keysDir = config.opensshPolicy.keysDir;
    logger = loggerScript;
    activationTag = "darwin.activationScripts.postActivation.openssh";
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

    # Ensure OpenSSH helper scripts are installed during the etc phase.
    system.activationScripts.etc.text = lib.mkAfter ''
      bash ${opensshActivationScript}
    '';

    # HM post-activation is wired at mkOrder 2000 in modules/darwin/default.nix.
    # Run CA/trust aggregation after HM extraction so runtime SSH key material exists.
    system.activationScripts.postActivation.text = lib.mkOrder 2100 ''
      bash ${opensshPostActivationScript}
    '';

  };
}
