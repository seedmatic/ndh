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
  ownsHostKey = config.ndh.hostKey.own;
  # The ed25519 path Tailscale SSH reads: the rdp-host copy sshd-host-identity-reload installs, or, once
  # the guest owns its host key, a link to it.
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key";
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

  # A pending host-key slot: its key is born here (host-key.nix), at every activation, idempotently. Never fatal:
  # the key is unused until recorded, and the next activation completes a run that stopped.
  system.activationScripts.ndhHostKeyGenerate = lib.mkIf (config.ndh.hostKey.generate != null) {
    deps = [ "specialfs" ];
    supportsDryActivation = false;
    text = ''
      if ! ${pkgs.bash}/bin/bash ${config.ndh.hostKey.generate}/bin/host-key-generate; then
        echo "[host-key] FAILED to generate or publish the pending host key; the next activation retries" >&2
      fi
    '';
  };

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
    hostKeyPaths = [ (if ownsHostKey then config.ndh.hostKey.file else hostKeyPath) ];
    # Without a certificate, a client verifying this guest falls back to the raw
    # key pinned in known_hosts, and a host-key rotation fails on every client.
    # An owned key's certificate is keys.yaml's, a store file. Otherwise the served
    # key IS rdp-host (hostkey-enrollment keeps them equal), and this path is the
    # extractor's symlink to the matching certificate, resolved by fingerprint; a
    # missing file is not fatal: sshd logs it and serves the key.
    hostCertificatePath =
      if ownsHostKey then "${config.ndh.hostKey.certificateFile}" else config.sshPaths.hostCertPublic;

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
    # NixOS generates every key listed here at boot and serves them all (rsa and
    # ed25519 by default). sshd serves the policy's keys only, rendered below.
    hostKeys = lib.mkForce [ ];
    settings = config.opensshPolicy.settings // {
      UsePAM = true;
      # Allow client to specify which address to bind for remote forwardsssh
      GatewayPorts = "clientspecified";
    };
    # HostKey lines (a settings attr would collapse them), then the shared daemon Include globs
    extraConfig =
      lib.concatMapStrings (p: "HostKey ${p}\n") config.opensshPolicy.hostKeys
      + (
        let
          lines = builtins.map (g: "Include ${g}") config.opensshPolicy.includeDaemonGlobs;
        in
        lib.concatStringsSep "\n" lines + "\n"
      )
      + ''
        # Enable remote forwarding of Unix domain sockets (for GPG agent forwarding)
        StreamLocalBindUnlink yes
        AllowStreamLocalForwarding yes
      ''
      # The restricted users' Match blocks, LAST: a Match runs to the end of the config, so anything after it
      # would apply to those users only.
      + config.opensshPolicy.restrictedUsersText;
  };

  # OpenSSH client configuration: the drop-ins under /etc/ssh/ssh_config.d first, the `Host *`
  # defaults after them — ssh keeps the FIRST value it obtains, so a default placed first would
  # shadow every specific stanza.
  programs.ssh = {
    extraConfig =
      (
        let
          lines = builtins.map (g: "Include ${g}") config.opensshPolicy.includeClientGlobs;
        in
        lib.concatStringsSep "\n" lines + "\n"
      )
      + ''

        Host *
          AddressFamily inet
          ServerAliveInterval 30
          ServerAliveCountMax 3
      '';
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
            "@systemHostKey@"
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
            # The fallback copies a previous rdp-host extraction; an owned key is no client identity.
            (if ownsHostKey then "" else hostKeyPath)
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
  ]
  # Tailscale SSH serves the keys it finds under /etc/ssh, not sshd's HostKey: the link makes it present
  # the owned key, and the removals leave no rdp-host private, nor a key of an earlier generation, on
  # the guest.
  ++ lib.optionals ownsHostKey (
    [ "L+ ${hostKeyPath} - - - - ${config.ndh.hostKey.file}" ]
    ++ map (path: "r ${path} - - - - -") (
      [ "${hostKeyPath}.pub" ]
      ++
        lib.concatMap
          (type: [
            "/etc/ssh/ssh_host_${type}_key"
            "/etc/ssh/ssh_host_${type}_key.pub"
          ])
          [
            "rsa"
            "ecdsa"
          ]
    )
  );

  # It reads them only at start, so the switch that flips ndh.hostKey.own restarts it once.
  systemd.services.tailscaled = lib.mkIf config.services.tailscale.enable {
    restartTriggers = [ (builtins.toJSON { inherit (config.ndh.hostKey) own file; }) ];
  };

  # Ensure all systemd services (including sshd) inherit a wrapper-first PATH
  systemd.globalEnvironment.PATH = config.opensshPolicy.setEnvPath;

  systemd.services.${ndhSystemd.mkUnitName "hostkey-enrollment-check"} = lib.mkIf (!ownsHostKey) {
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
  # a definition OF it on it recurses. A guest owning its host key has nothing to copy.
  systemd.services.${homeManagerServiceName} =
    lib.mkIf
      (!ownsHostKey && lib.hasAttrByPath [ "home-manager" "users" config.profile.user.name ] config)
      {
        serviceConfig.ExecStartPost = [
          "+${pkgs.bash}/bin/bash ${sshdHostIdentityReloadScript}/bin/openssh-sshd-host-identity-reload"
        ];
      };

  # An owned host key missing is ONE fault, said once: sshd's start fails on this
  # dependency. Not an ExecStartPre: sshd's Restart=always would retry it up to the
  # start limit, and sshd, never generating a key, has nothing else to serve.
  systemd.services.${ndhSystemd.mkUnitName "host-key-check"} = lib.mkIf ownsHostKey {
    description = "Refuse sshd's start when this guest's own host key is not placed (@codebase)";
    requiredBy = [ "sshd.service" ];
    before = [ "sshd.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${config.ndh.hostKey.check}";
    };
  };

  # Keep sshd start robust across boot ordering by binding it to both
  # canonical multi-user and NDH contributed targets.
  systemd.services.sshd.wantedBy = lib.mkAfter [
    contributedTargetName
  ];

}
