{
  self,
  config,
  pkgs,
  lib,
  ndh,
  ...
}:
let
  ndhContext = ndh.context;
  ndhCommon = "${self}/modules/.common.d";
  profile = config.profile;
  userHome = profile.user.home;
  userName = profile.user.name;
  sshPaths = config.sshPaths;
  hostKeysDir = sshPaths.authoritySecretsDir;
  clientKeyName = builtins.baseNameOf sshPaths.privKeyFile;
  hostKeyPrivateFile = sshPaths.privKeyFile;
  hostKeyPublicCert = sshPaths.hostCertPublic;
  caPublicKeyFile = "${config.opensshPolicy.keysDir}/trusted-user-ca.pub";
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  opensshAuthzTools = ndh.store.installBinScriptBundle "openssh-authz-tools" {
    openssh-principals-command = pkgs.replaceVars "${ndhCommon}/ssh/authorized-principals-command.sh" {
      nixBashTrampoline = nixBashTrampoline;
    };
    openssh-group-authorized-keys = pkgs.replaceVars "${ndhCommon}/ssh/ssh-group-authorized-keys.sh" {
      nixBashTrampoline = nixBashTrampoline;
      authorizedKeysDir = config.opensshPolicy.authorizedKeysDir;
    };
  };
  principalsScriptStore = "${opensshAuthzTools}/bin/openssh-principals-command";
  groupKeysScriptStore = "${opensshAuthzTools}/bin/openssh-group-authorized-keys";
  inherit (lib) mkIf optionalString concatStringsSep;

  # Derive principals based on profile and hostname.
  # All hosts accept the same principal set to allow cross-host connections.
  hostAlias =
    if (profile.host ? hostAlias && profile.host.hostAlias != null) then
      profile.host.hostAlias
    else
      profile.host.hostName;
  # AuthorizedPrincipalsCommand traverses the principals-yaml recursively
  # (yq `..` idiom), so the outer wrapper name is inert.
  principalsYamlLabel = "host";

  allPrincipals = [
    "committed"
    "nikopol"
    "bioskop"
    # nix-store: cert principal carried by the identity provisioned via
    # modules/.common.d/nix-store-identity.nix. The matching user account
    # exists locally on this host, and its AuthorizedPrincipalsCommand needs
    # to emit `nix-store` so sshd accepts the cert-signed login.
    "nix-store"
  ];

  # Format principals as YAML list with proper indentation (6 spaces for list items)
  formatPrincipals = principals: concatStringsSep "\n" (map (p: "              - ${p}") principals);

  sshKeysYamlText = ''
          # Certificate principal validation for ${hostAlias}.
          # Managed by modules/darwin/openssh.nix - regenerated on darwin-rebuild.
          # Accepts all profile principals to allow cross-host connections.
          profiles:
            ${principalsYamlLabel}:
              ${clientKeyName}:
                principals:
    ${formatPrincipals allPrincipals}
  '';

  ndhSshdConfigText =
    let
      boolToYesNo = v: if v then "yes" else "no";
      renderValue = v: if builtins.isBool v then boolToYesNo v else builtins.toString v;
      hostKeyLines = map (p: "HostKey ${p}") config.opensshPolicy.hostKeys;
      policyLines = lib.mapAttrsToList (k: v: "${k} ${renderValue v}") config.opensshPolicy.settings;
      all = hostKeyLines ++ policyLines;
    in
    lib.concatStringsSep "\n" all + "\n";

  baseSshdConfigText = ''
    # Managed by nix-darwin (modules/darwin/openssh.nix)
    # Keep a canonical base file so sshd always has an entrypoint.
    Include /etc/ssh/sshd_config.d/*.conf
  '';

  canonicalAuthorizedKeysDropIn = ''
    # Managed by modules/darwin/openssh.nix
    # Keep AuthorizedKeysCommand canonical and consistent with NDH policy.
    AuthorizedKeysCommand ${config.opensshPolicy.canonicalCommandDir}/${config.opensshPolicy.canonicalGroupKeysCommandName} %u
    AuthorizedKeysCommandUser ${config.opensshPolicy.groupCommandUser}
  '';

  opensshActivationScript = ndh.store.installBinScript "openssh-activation" (
    pkgs.replaceVars ./openssh.d/openssh-activation.sh {
      nixBashTrampoline = nixBashTrampoline;
      groupKeysScriptStore = groupKeysScriptStore;
      principalsScriptStore = principalsScriptStore;
      groupKeysCommand = config.opensshPolicy.canonicalGroupKeysCommandName;
      principalsCommand = config.opensshPolicy.canonicalPrincipalsCommandName;
    }
  );

  opensshPostActivationScript = ndh.store.installBinScript "openssh-post-activation" (
    pkgs.replaceVars ./openssh.d/post-activation.sh {
      nixBashTrampoline = nixBashTrampoline;
      hostKeysDir = hostKeysDir;
      keysDir = config.opensshPolicy.keysDir;
      loggerTag = "darwin.activationScripts.postActivation.openssh";
    }
  );

in
{
  imports = [
    "${ndhCommon}/openssh-policy.nix"
    "${ndhCommon}/ssh-paths.nix"
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

    # Keep NDH policy in a dedicated late drop-in so precedence is explicit.
    # nix-darwin still manages service enablement and host key lifecycle.
    environment.etc."ssh/sshd_config".text = baseSshdConfigText;
    # Canonicalize legacy 101 drop-in emitted by nix-darwin to avoid /bin/cat
    # probing per-user files (e.g. /etc/ssh/nix_authorized_keys.d/%u).
    environment.etc."ssh/sshd_config.d/101-authorized-keys.conf".text = canonicalAuthorizedKeysDropIn;
    environment.etc."ssh/sshd_config.d/999-ndh.conf".text = ndhSshdConfigText;

    # Darwin option surface for OpenSSH is intentionally small
    # (enable + extraConfig in the currently pinned nix-darwin). Keep NDH
    # policy in 999-ndh.conf for explicit ordering.
    services.openssh = {
      enable = true;
    };

    # Ensure OpenSSH helper scripts are installed during the etc phase.
    system.activationScripts.etc.text = lib.mkAfter ''
      bash ${opensshActivationScript}/bin/openssh-activation
    '';

    # HM post-activation is wired at mkOrder 2000 in modules/darwin/default.nix.
    # Run CA/trust aggregation after HM extraction so runtime SSH key material exists.
    system.activationScripts.postActivation.text = lib.mkOrder 2100 ''
      bash ${opensshPostActivationScript}/bin/openssh-post-activation
    '';

  };
}
