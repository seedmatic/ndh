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

  userHome =
    if config ? profile && config.profile ? user && config.profile.user ? home then
      toString config.profile.user.home
    else
      "/root";
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  ownsHostKey = config.ndh.hostKey.own;
  # The ed25519 path Tailscale SSH reads: a link to the guest's own host key; NixOS's own generated key otherwise.
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
  sshdAutostartCheckTag = "nixos.services.ndh.sshdAutostartCheck";
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
    # there at build time, so the operator bare pubkey declared in
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
    # A fleet machine serves its own host key and its keys.yaml certificate (without one, a client falls back to
    # the raw key pinned in known_hosts, and a rotation fails on every client). Any other configuration (the
    # generic runtime layer) serves the key NixOS generates at first boot, uncertified.
    hostKeyPaths = [ (if ownsHostKey then config.ndh.hostKey.file else hostKeyPath) ];
    hostCertificatePath = if ownsHostKey then "${config.ndh.hostKey.certificateFile}" else null;

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
    # NixOS generates every key listed here at boot and serves them all (rsa and ed25519 by default). sshd serves
    # the policy's keys only, rendered below: a fleet machine's own, or, for any other configuration, the one
    # ed25519 NixOS generates here at first boot.
    hostKeys = lib.mkForce (
      lib.optional (!ownsHostKey) {
        path = hostKeyPath;
        type = "ed25519";
      }
    );
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
            "@loggerTag@"
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
            loggerTag
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
  # the guest's own key, and the removals leave no key of an earlier generation on the guest.
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

  # It reads them only at start, so a switch that changes the served key restarts it once.
  systemd.services.tailscaled = lib.mkIf config.services.tailscale.enable {
    restartTriggers = [ config.ndh.hostKey.file ];
  };

  # Ensure all systemd services (including sshd) inherit a wrapper-first PATH
  systemd.globalEnvironment.PATH = config.opensshPolicy.setEnvPath;

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
