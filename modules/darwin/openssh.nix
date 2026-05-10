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
  hostKeysDir = sshPaths.secretsKeysDir;
  clientKeyName = builtins.baseNameOf sshPaths.privKeyFile;
  # Host keys now extracted to user directory (keys with both system + user profiles)
  hostKeyPrivateFile = sshPaths.privKeyFile;
  hostKeyPublicCert = "${sshPaths.secretsKeysDir}/${clientKeyName}-server-cert.pub";
  caPublicKeyFile = "${config.opensshPolicy.keysDir}/trusted-user-ca.pub";
  authorizedPrincipalsInputPath = "${config.opensshPolicy.canonicalCommandDir}/authorized-principals-command.yaml";
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  opensshAuthzTools = ndh.store.installBinScriptBundle "openssh-authz-tools" {
    openssh-principals-command = pkgs.replaceVars "${ndhCommon}/ssh/authorized-principals-command.sh" {
      nixBashTrampoline = nixBashTrampoline;
      principalsInputPath = authorizedPrincipalsInputPath;
    };
    openssh-group-authorized-keys = pkgs.replaceVars "${ndhCommon}/ssh/ssh-group-authorized-keys.sh" {
      nixBashTrampoline = nixBashTrampoline;
      authorizedKeysDir = config.opensshPolicy.authorizedKeysDir;
    };
  };
  principalsScriptStore = "${opensshAuthzTools}/bin/openssh-principals-command";
  groupKeysScriptStore = "${opensshAuthzTools}/bin/openssh-group-authorized-keys";
  inherit (lib) mkIf optionalString concatStringsSep;

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

    # CA aggregation happens in-place inside sshPaths.systemKeysDir during
    # the ssh-keys enrichment activation pass (modules/darwin/ssh-keys-
    # enrichment.nix). No separate post-activation step needed — sshd's
    # TrustedUserCAKeys points directly at that aggregate.
  };
}
