{
  worktreePath,
  config,
  pkgs,
  lib,
  ndh,
  catalog,
  ...
}:
let
  ndhContext = ndh.context;
  ndhCommon = (worktreePath.of "modules/.common.d");
  profile = config.profile;
  userHome = profile.user.home;
  userName = profile.user.name;
  sshPaths = config.sshPaths;
  hostKeysDir = sshPaths.secretsKeysDir;
  clientKeyName = builtins.baseNameOf sshPaths.privKeyFile;
  ownsHostKey = config.ndh.hostKey.own;
  # Until the seat owns its host key: rdp-host, extracted to the user's directory with its certificate.
  hostKeyPrivateFile = sshPaths.privKeyFile;
  hostKeyPublicCert = "${sshPaths.secretsKeysDir}/${clientKeyName}-server-cert.pub";
  caPublicKeyFile = "${config.opensshPolicy.keysDir}/trusted-user-ca.pub";
  authorizedPrincipalsInputPath = "${config.opensshPolicy.canonicalCommandDir}/authorized-principals-command.yaml";
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  opensshAuthzTools = import (worktreePath.of "modules/.common.d/ssh/authz-tools.nix") {
    inherit pkgs ndh nixBashTrampoline;
    sshCommonDir = "${ndhCommon}/ssh";
    principalsInputPath = authorizedPrincipalsInputPath;
    authorizedKeysDir = config.opensshPolicy.authorizedKeysDir;
  };
  principalsScriptStore = "${opensshAuthzTools}/bin/openssh-principals-command";
  groupKeysScriptStore = "${opensshAuthzTools}/bin/openssh-group-authorized-keys";
  inherit (lib) mkIf optionalString concatStringsSep;

  # The NixOS guest that mounts this operator seat's git stores (roles × keys S3b), by the inventory.
  sshfsGuest = (catalog.netplan.baremetal.${config.networking.hostName} or { }).nixosHostname or null;
  sshfsKeyName = "sshfs-${sshfsGuest}";
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
    (worktreePath.of "modules/.common.d/openssh-policy.nix")
    (worktreePath.of "modules/.common.d/ssh-paths.nix")
  ];

  # Read-only sftp and nothing else: `restrict` drops pty, port/agent/X11 forwarding and ~/.ssh/rc, and
  # the forced command replaces whatever the client asks for, a shell or the sftp subsystem alike. sshd
  # runs a forced `internal-sftp` in process, so the operator's login shell, its rc files and BASH_ENV never
  # run and cannot write into the sftp stream. An option so the real-sshd check runs this very string.
  options.ndh.sshfs.authorizedOptions = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = ''restrict,command="internal-sftp -R"'';
    description = "The authorized_keys options of the guest's sshfs key on its operator seat.";
  };

  # Not read-only only so the eval checks can give a test configuration a public that keys.yaml does not hold.
  options.ndh.sshfs.guestKeyLines = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    internal = true;
    default = lib.optionals (sshfsGuest != null && config.ndh.keysYaml.keys ? ${sshfsKeyName}) (
      config.ndh.keysYaml.authorizedLinesFor [ sshfsKeyName ]
    );
    description = ''
      The authorized_keys lines of this seat's NixOS guest's sshfs key, from its public recorded in keys.yaml
      (`sshfs-<guest>`), one per slot; none until it is recorded. Authorized for the operator with
      read-only sftp only.
    '';
  };

  config = {
    # The guest's sshfs key: an authorized_keys line, not a certificate, because it must hold on THIS seat
    # only, with its forced command; a certificate principal is honored by every sshd trusting the
    # authority. nix-darwin writes the lines to /etc/ssh/nix_authorized_keys.d/<user>, which the group-keys
    # AuthorizedKeysCommand reads: a command, because sshd does not read that store symlink as a file.
    users.users.${userName}.openssh.authorizedKeys.keys = map (
      line: "${config.ndh.sshfs.authorizedOptions} ${line}"
    ) config.ndh.sshfs.guestKeyLines;

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
      hostKeyPaths = [ (if ownsHostKey then config.ndh.hostKey.file else hostKeyPrivateFile) ];
      hostCertificatePath =
        if ownsHostKey then "${config.ndh.hostKey.certificateFile}" else hostKeyPublicCert;

      # Force IPv4 only for SSH server; expose the SFTP subsystem explicitly.
      # Our canonical /etc/ssh/sshd_config is a bare `Include …` (baseSshdConfigText),
      # which drops macOS's default `Subsystem sftp` line — without re-adding it here
      # sshd answers exec but resets every SFTP channel, so sshfs (SFTP-based) fails.
      extraSettings = {
        AddressFamily = "inet";
        Subsystem = "sftp internal-sftp";
      };

    };

    # opensshPolicy now manages /etc/ssh/ssh_known_hosts (the host authority, for
    # root as for everyone). bioskop had an unmanaged one — leftovers of an old
    # nix-darwin linux-builder keyscan: six `# localhost:22` comments and two pins
    # for that builder, which bootstrap-linux-builder no longer reads (it keeps its
    # own /var/root/.ssh/known_hosts.linux-builder). Without its hash here,
    # nix-darwin aborts the activation on an unexpected file in /etc; with it, the
    # old file is moved aside as *.before-nix-darwin.
    environment.etc."ssh/ssh_known_hosts".knownSha256Hashes = [
      "94534bca4c585b03705f6b0195da955c8fc12336a6dbbd35429e1d6b2e992e5c"
    ];

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

    # NDH policy stays in 999-ndh.conf for explicit ordering. nix-darwin's own hostKeys default would
    # render macOS's /etc/ssh/ssh_host_{rsa,ecdsa,ed25519}_key into 099-host-keys.conf beside ours, so
    # sshd served those raw keys too: the seat serves its policy's host keys only, as the NixOS guests do.
    services.openssh = {
      enable = true;
      hostKeys = lib.mkForce [ ];
    };

    # Ensure OpenSSH helper scripts are installed during the etc phase. launchd starts sshd per
    # connection, so a missing owned key is said here, without failing the rest of the activation.
    system.activationScripts.etc.text = lib.mkAfter (
      ''
        bash ${opensshActivationScript}/bin/openssh-activation
      ''
      + lib.optionalString ownsHostKey ''
        ${config.ndh.hostKey.check} || true
      ''
    );

    # CA aggregation happens in-place inside sshPaths.systemKeysDir during
    # the ssh-keys enrichment activation pass (modules/darwin/ssh-keys-
    # enrichment.nix). No separate post-activation step needed — sshd's
    # TrustedUserCAKeys points directly at that aggregate.
  };
}
