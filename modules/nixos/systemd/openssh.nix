{
  config,
  pkgs,
  lib,
  ndh,
  ndhSystemd,
  worktreePath,
  ...
}:

let
  ndhContext = ndh.context;
  ndhCommon = (worktreePath.of "modules/.common.d");
  dollar = "$";
  hostname =
    if config.networking.hostName != "" then config.networking.hostName else "nix-darwin-home";
  profile =
    config.profile or {
      host = {
        hostName = hostname;
      };
    };
  # See modules/darwin/openssh.nix for the rationale — the outer wrapper
  # in the principals yaml is traversed recursively so any fixed label
  # works.
  principalsYamlLabel = "host";
  hostIdent =
    if (profile.host ? hostAlias && profile.host.hostAlias != null && profile.host.hostAlias != "") then
      profile.host.hostAlias
    else
      profile.host.hostName;
  clientKeyName = builtins.baseNameOf config.sshPaths.privKeyFile;

  userHome =
    if config ? profile && config.profile ? user && config.profile.user ? home then
      toString config.profile.user.home
    else
      "/root";
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  # Reuse existing host key generated/managed by NixOS (ed25519 preferred)
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key"; # runtime path consumed by sshd
  keysDir = config.opensshPolicy.keysDir;
  authorizedPrincipalsInputPath = "${config.opensshPolicy.canonicalCommandDir}/authorized-principals-command.yaml";
  caPublicKeyPath = "${keysDir}/trusted-user-ca.pub"; # generated from all *-ca.pub keys in keysDir

  opensshAuthzTools = import (worktreePath.of "modules/.common.d/ssh/authz-tools.nix") {
    inherit pkgs ndh nixBashTrampoline;
    sshCommonDir = "${ndhCommon}/ssh";
    principalsInputPath = authorizedPrincipalsInputPath;
    authorizedKeysDir = config.opensshPolicy.authorizedKeysDir;
  };
  principalsScriptStore = "${opensshAuthzTools}/bin/openssh-principals-command";
  groupKeysScriptStore = "${opensshAuthzTools}/bin/openssh-group-authorized-keys";
  # Use the wrapped activation logger packaged into the system closure
  loggerTag = "nixos.activationScripts.sshGroupKeys";
  hasSopsInstallSecretsService = builtins.hasAttr "sops-install-secrets" config.systemd.services;
  sshKeysEnrichmentServiceName = ndhSystemd.mkServiceName "ssh-keys-enrichment";
  contributedTargetName = ndhSystemd.contributedTargetName;
  hasSshKeysEnrichmentService = builtins.hasAttr (ndhSystemd.mkUnitName "ssh-keys-enrichment") config.systemd.services;
  homeManagerServiceName = "home-manager-${config.profile.user.name}";
  hostkeyEnrollmentCheckTag = "nixos.services.ndh.hostkeyEnrollmentCheck";
  authorizedKeysCheckTag = "nixos.services.ndh.authorizedKeysCheck";
  sshdAutostartCheckTag = "nixos.services.ndh.sshdAutostartCheck";
  hostkeyEnrollmentCheckScript = ndh.store.installBinScript "openssh-hostkey-enrollment-check" (
    pkgs.replaceVars ./openssh.d/hostkey-enrollment-check.sh {
      nixBashTrampoline = nixBashTrampoline;
      logTag = hostkeyEnrollmentCheckTag;
      userPrivateSourceDir = config.sshPaths.secretsKeysDir;
      # userCaSourceDir is a misnomer kept for the script's substitution
      # slot: the variable holds the per-key `.pub` directory (used to
      # read `<key>.pub` alongside its private counterpart), which
      # ssh-extract-keys routes to `target_dir = "user"` → secretsKeysDir.
      # Everything the extractor writes lands in secretsKeysDir, scoped by suffix.
      userCaSourceDir = config.sshPaths.secretsKeysDir;
      systemHostKeyPub = "${hostKeyPath}.pub";
      clientKeyName = clientKeyName;
    }
  );
  authorizedKeysCheckScript = ndh.store.installBinScript "openssh-authorized-keys-check" (
    pkgs.replaceVars ./openssh.d/authorized-keys-check.sh {
      nixBashTrampoline = nixBashTrampoline;
      logTag = authorizedKeysCheckTag;
      authorizedKeysFile = "${config.opensshPolicy.authorizedKeysDir}/${config.profile.user.name}";
      expectedPublicKeyFile = config.sshPaths.hostPublicKeyFile;
      profileUserName = config.profile.user.name;
    }
  );
  sshdHostIdentityReloadTag = "nixos.services.ndh.sshdHostIdentityReload";
  sshdHostIdentityReloadScript = ndh.store.installBinScript "openssh-sshd-host-identity-reload" (
    pkgs.replaceVars ./openssh.d/sshd-host-identity-reload.sh {
      nixBashTrampoline = nixBashTrampoline;
      logTag = sshdHostIdentityReloadTag;
      hostKeySource = config.sshPaths.privKeyFile;
      hostKeyPublicSource = config.sshPaths.hostPublicKeyFile;
      systemHostKey = hostKeyPath;
      hostCertificatePath = config.sshPaths.hostCertPublic;
    }
  );
  sshdAutostartCheckScript = ndh.store.installBinScript "openssh-sshd-autostart-check" (
    pkgs.replaceVars ./openssh.d/sshd-autostart-check.sh {
      nixBashTrampoline = nixBashTrampoline;
      logTag = sshdAutostartCheckTag;
    }
  );
in
{
  imports = [
    (worktreePath.of "modules/.common.d/openssh-policy.nix")
    (worktreePath.of "modules/.common.d/ssh-paths.nix")
  ];

  opensshPolicy = {
    enable = true;
    platformRendersAuthorizedKeysFile = lib.mkDefault false;
    # NixOS guest policy: authorize via system-managed key files only.
    # Do not read per-user ~/.ssh/authorized_keys for server authentication.
    #
    # `/etc/ssh/authorized_keys.d/%u` is the static, Nix-baked rescue
    # path: NixOS renders `users.users.<u>.openssh.authorizedKeys.keys`
    # there at build time, so the rdp-host bare pubkey declared in
    # modules/nixos/users.nix is always present even before the
    # ssh-keys-enrichment unit runs (or if it fails). Listed first so
    # sshd consults it before the runtime-managed dir.
    authorizedKeysFiles = [
      "/etc/ssh/authorized_keys.d/%u"
      "${config.opensshPolicy.authorizedKeysDir}/%u"
    ];
    setEnvPath = lib.mkDefault "/run/wrappers/bin:/run/current-system/sw/bin:/bin:/usr/bin";
    nonInteractivePrimaryPath = lib.mkDefault "/run/wrappers/bin";
    trustedCAPath = caPublicKeyPath;
    principalsCommandSource = principalsScriptStore;
    groupKeysCommandSource = groupKeysScriptStore;
    hostKeyPaths = [ hostKeyPath ];
    # Without a certificate, a client verifying this guest falls back to the raw
    # key pinned in known_hosts, and a host-key rotation fails on every client.
    # The served key IS rdp-host (hostkey-enrollment keeps them equal), and this
    # path is the extractor's symlink to the matching certificate, resolved by
    # fingerprint. A missing file is not fatal: sshd logs it and serves the key.
    hostCertificatePath = config.sshPaths.hostCertPublic;

    # Force IPv4 only for SSH server
    extraSettings = {
      AddressFamily = "inet";
      # Bootstrap requirement: allow root with key-based auth only.
      PermitRootLogin = "prohibit-password";
    };
  };

  services.openssh = {
    enable = true;
    authorizedKeysFiles = lib.mkForce config.opensshPolicy.authorizedKeysFiles;
    settings = config.opensshPolicy.settings // {
      UsePAM = true;
      # Allow client to specify which address to bind for remote forwardsssh
      GatewayPorts = "clientspecified";
    };
    # Render shared daemon Include globs
    extraConfig =
      (
        let
          lines = builtins.map (g: "Include ${g}") config.opensshPolicy.includeDaemonGlobs;
        in
        lib.concatStringsSep "\n" lines + "\n"
      )
      + ''
        # Enable remote forwarding of Unix domain sockets (for GPG agent forwarding)
        StreamLocalBindUnlink yes
        AllowStreamLocalForwarding yes
      '';
  };

  # OpenSSH client configuration: allow includes for drop-ins under /etc/ssh/ssh_config.d
  programs.ssh = {
    extraConfig = ''
      Host *
        AddressFamily inet
        ServerAliveInterval 30
        ServerAliveCountMax 3
    ''
    + (
      let
        lines = builtins.map (g: "Include ${g}") config.opensshPolicy.includeClientGlobs;
      in
      "\n" + lib.concatStringsSep "\n" lines + "\n"
    );
  };

  # Ensure the group authorized keys directory exists and create keys
  system.activationScripts = {
    sshGroupKeys = {
      text =
        builtins.replaceStrings
          [
            "@nixBashTrampoline@"
            "@authorizedKeysDir@"
            "@keysDir@"
            "@hostname@"
            "@principalsCommand@"
            "@groupCommand@"
            "@principalsScript@"
            "@groupKeysScript@"
            "@profileUserName@"
            "@loggerTag@"
            "@userPrivateSourceDir@"
            "@userCaSourceDir@"
            "@clientKeyName@"
          ]
          [
            nixBashTrampoline
            config.opensshPolicy.authorizedKeysDir
            config.opensshPolicy.keysDir
            hostname
            config.opensshPolicy.canonicalPrincipalsCommandName
            config.opensshPolicy.canonicalGroupKeysCommandName
            "${principalsScriptStore}"
            "${groupKeysScriptStore}"
            config.profile.user.name
            loggerTag
            config.sshPaths.secretsKeysDir
            # userCaSourceDir placeholder now fed the per-key `.pub`
            # directory (secretsKeysDir), matching ssh-extract-keys's
            # `target_dir = "user"` routing.  Kept the misnomer for the
            # substitution slot to avoid churn in the shell script.
            config.sshPaths.secretsKeysDir
            clientKeyName
          ]
          (builtins.readFile ./openssh.d/activation.sh);
    };
  };

  # ssh non-interactive session finds the setuid sudo via /bin or /usr/bin
  # Directory ownership rules for the user-scope ssh secrets tree
  # (secretsRootDir / secretsKeysDir) live in
  # modules/nixos/systemd/hm-state-dirs.nix, which is the canonical
  # source of truth for `~/.local/**` layout and uses recursive `Z`
  # rules so the tree self-heals after the root-run enrichment service
  # writes fresh files.
  systemd.tmpfiles.rules = [
    "d /run/secrets/nix-darwin-home 0755 root root - -"
    "L+ /bin/sudo - - - - /run/wrappers/bin/sudo"
    "L+ /usr/bin/sudo - - - - /run/wrappers/bin/sudo"
    "L+ /bin/bash - - - - /run/current-system/sw/bin/bash"
    "d /run/ndh/ssh 0775 ${config.profile.user.name} ${config.profile.user.name} - -"
  ];

  # Ensure all systemd services (including sshd) inherit a wrapper-first PATH
  systemd.globalEnvironment.PATH = config.opensshPolicy.setEnvPath;

  systemd.services.${ndhSystemd.mkUnitName "hostkey-enrollment-check"} = {
    description = "Check whether host key enrollment into encrypted secrets is required (@codebase)";
    wantedBy = [ "sshd.service" ];
    before = [ "sshd.service" ];
    wants = lib.optionals hasSopsInstallSecretsService [ "sops-install-secrets.service" ];
    after = lib.optionals hasSopsInstallSecretsService [ "sops-install-secrets.service" ];
    path = with pkgs; [
      coreutils
      gawk
      openssh
      util-linux
      yq-go
    ];
    serviceConfig = {
      Type = "oneshot";
      User = config.profile.user.name;
      Group = config.profile.user.name;
      Environment = [ "HOME=${userHome}" ];
      ExecStart = "${pkgs.bash}/bin/bash ${hostkeyEnrollmentCheckScript}/bin/openssh-hostkey-enrollment-check";
    };
  };

  systemd.services.${ndhSystemd.mkUnitName "authorized-keys-check"} = {
    description = "Verify expected system authorized key is installed (informational, does not gate sshd) (@codebase)";
    # WantedBy (not RequiredBy) + no `before = sshd.service`: this is a
    # post-flight assertion on the managed authorized_keys pipeline, not a
    # prerequisite for sshd to come up.  If the operator's key is missing
    # or mismatched, root key-based emergency SSH must still work so the
    # operator can diagnose the enrichment / extraction failure — blocking
    # sshd here turned a soft misconfiguration into a hard no-login outage.
    wantedBy = [ "multi-user.target" ];
    wants = lib.optionals hasSshKeysEnrichmentService [
      sshKeysEnrichmentServiceName
    ];
    after = [
      "sshd.service"
    ]
    ++ lib.optionals hasSshKeysEnrichmentService [
      sshKeysEnrichmentServiceName
    ];
    path = with pkgs; [
      coreutils
      gnugrep
      gawk
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = "${pkgs.bash}/bin/bash ${authorizedKeysCheckScript}/bin/openssh-authorized-keys-check";
    };
  };

  systemd.services.${ndhSystemd.mkUnitName "sshd-autostart-check"} = {
    description = "Validate sshd autostart state after contributed target activation (@codebase)";
    wantedBy = [ contributedTargetName ];
    after = [ "sshd.service" ];
    path = with pkgs; [
      coreutils
      systemd
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = "${pkgs.bash}/bin/bash ${sshdAutostartCheckScript}/bin/openssh-sshd-autostart-check";
    };
  };

  # The home-manager unit is what extracts the host key and its certificate, so
  # it is the one that installs the key into /etc/ssh and tells sshd to pick
  # both up — `+` because the unit runs as the user. Never
  # the other way round (sshd After= home-manager): sshd must not wait on the key
  # pipeline, or a broken extraction locks the operator out.
  # Gated on home-manager.users, not on config.systemd.services: conditioning
  # a definition OF it on it recurses.
  systemd.services.${homeManagerServiceName} =
    lib.mkIf (lib.hasAttrByPath [ "home-manager" "users" config.profile.user.name ] config)
      {
        serviceConfig.ExecStartPost = [
          "+${pkgs.bash}/bin/bash ${sshdHostIdentityReloadScript}/bin/openssh-sshd-host-identity-reload"
        ];
      };

  # Keep sshd start robust across boot ordering by binding it to both
  # canonical multi-user and NDH contributed targets.
  systemd.services.sshd.wantedBy = lib.mkAfter [
    contributedTargetName
  ];

}
