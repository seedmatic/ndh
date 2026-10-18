# A metalspace's cluster builder (docs/private-binary-cache-spec.adoc, [[cluster-builds]]): the NixOS system
# of its own unprivileged Incus container, which builds what that cluster's nodes and workloads ask over
# ssh-ng, and nothing else. It holds no attic token and no secret of the fabric; its host key and its nix
# signing key are born inside, at its first start, and only their publics leave.
#
# An LXC image, not ndh's empty-rootfs containers (incus-nixos-container.nix): those run on a store the
# NixOS guest composes, which an unprivileged container cannot write, and a builder writes. Its store is the
# image's rootfs, which Incus idmaps. A new system is a new image, hence a new host key and a new nix key.
#
# From nixpkgs' lxc-container.nix only the image: lxc-instance-common.nix, which it imports, opens a
# password-less root login, enables sshd with its defaults and copies a channel in.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  cfg = config.ndh.clusterBuilder;
  account = "cluster-build";
  stateDir = "/var/lib/cluster-builder";
  signingKey = "${stateDir}/signing.sec";
  # nix 2.34.9 (src/nix/unix/daemon.cc): without --process-ops the endpoint relays the client's ops to the
  # real daemon after answering them as trusted itself, so build-remote takes the trusted path; only the
  # three flags together make the endpoint itself untrusted. --force-untrusted needs daemon-trust-override,
  # read from nix.conf before the flags.
  endpoint =
    if cfg.trustedClient then
      "${config.nix.package}/bin/nix-daemon --stdio"
    else
      "${config.nix.package}/bin/nix-daemon --stdio --force-untrusted --process-ops";
  untrustedFeatures = [
    "daemon-trust-override"
    "mounted-ssh-store"
  ];
in
{
  imports = [
    "${modulesPath}/virtualisation/lxc-container.nix"
    "${modulesPath}/virtualisation/lxc-image-metadata.nix"
  ];
  disabledModules = [ "${modulesPath}/virtualisation/lxc-instance-common.nix" ];

  options.ndh.clusterBuilder = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "The container's host name.";
    };
    address = lib.mkOption {
      type = lib.types.str;
      description = "Its fabric address, with prefix length.";
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      description = "Its fabric gateway: the NixOS guest, its way to the upstream caches.";
    };
    nameservers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Resolvers for the upstream caches.";
    };
    allowedSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "The sources admitted on tcp/22: that cluster's nodes.";
    };
    userCaKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "The user CAs whose certificates at principal `${account}` this builder admits: that cluster's nodes'.";
    };
    trustedClient = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether `${account}` is a trusted user of this daemon: the spec's fallback (A), taken only if test 1
        fails. Trusted, a node can also import unsigned paths and override the daemon's settings.
      '';
    };
    signingKeyName = lib.mkOption {
      type = lib.types.str;
      description = "The name of the nix signing key generated inside at first start.";
    };
  };

  config = {
    networking.hostName = cfg.name;
    networking.useDHCP = false;
    systemd.network.enable = true;
    services.resolved.enable = false;
    networking.nameservers = cfg.nameservers;
    systemd.network.networks."10-fabric" = {
      matchConfig.Name = "eth0";
      address = [ cfg.address ];
      gateway = [ cfg.gateway ];
      networkConfig.LinkLocalAddressing = "no";
    };
    # The iptables firewall needs xt_* modules a container cannot load.
    networking.nftables.enable = true;
    networking.firewall.extraInputRules = ''
      ip saddr { ${lib.concatStringsSep ", " cfg.allowedSources} } tcp dport 22 accept
    '';

    users.users.root.hashedPassword = "!";
    users.mutableUsers = false;
    users.groups.${account} = { };
    users.users.${account} = {
      isSystemUser = true;
      group = account;
      # sshd runs the forced command through the account's shell.
      shell = pkgs.bashInteractive;
    };
    nix.channel.enable = false;
    documentation.enable = false;

    environment.etc."ssh/cluster-build-user-ca.pub".text =
      lib.concatStringsSep "\n" cfg.userCaKeys + "\n";
    environment.etc."ssh/principals/${account}".text = "${account}\n";
    services.openssh = {
      enable = true;
      startWhenNeeded = false;
      openFirewall = false;
      authorizedKeysInHomedir = false;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ account ];
        X11Forwarding = false;
        AllowTcpForwarding = "no";
        AllowAgentForwarding = false;
        AllowStreamLocalForwarding = "no";
        PermitTunnel = "no";
        PermitTTY = false;
        PermitUserRC = false;
        GatewayPorts = "no";
      };
      # No sftp subsystem: ForceCommand would win anyway, but the builder offers none.
      allowSFTP = false;
      extraConfig = ''
        TrustedUserCAKeys /etc/ssh/cluster-build-user-ca.pub
        AuthorizedPrincipalsFile /etc/ssh/principals/%u
        Match User ${account}
          ForceCommand ${endpoint}
      '';
    };

    nix.settings = {
      sandbox = true;
      # Without it, a sandbox the container refuses is silently dropped.
      sandbox-fallback = false;
      trusted-users = [ "root" ] ++ lib.optional cfg.trustedClient account;
      allowed-users = [
        "root"
        account
      ];
      substituters = [ "https://cache.nixos.org" ];
      trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
      # A client may name no substituter of its own.
      trusted-substituters = [ ];
      require-sigs = true;
      # It forwards nothing: a builder that cannot send cannot chain.
      builders = "";
      secret-key-files = [ signingKey ];
      experimental-features = [ "nix-command" ] ++ lib.optionals (!cfg.trustedClient) untrustedFeatures;
      min-free = 2 * 1024 * 1024 * 1024;
      max-free = 8 * 1024 * 1024 * 1024;
    };

    assertions = [
      {
        assertion = config.nix.settings.sandbox == true && config.nix.settings.sandbox-fallback == false;
        message = "ndh.clusterBuilder: the builder builds sandboxed, with no fallback";
      }
      {
        assertion = config.nix.settings.trusted-substituters == [ ] && config.nix.settings.builders == "";
        message = "ndh.clusterBuilder: no client substituter, no onward builder";
      }
      {
        assertion = cfg.trustedClient || !(lib.elem account config.nix.settings.trusted-users);
        message = "ndh.clusterBuilder: ${account} is untrusted unless trustedClient is set";
      }
    ];

    # Its nix key, born here at first start; the public is logged for the cluster's scenario to record.
    systemd.services.cluster-builder-signing-key = {
      description = "Generate this cluster builder's nix signing key";
      wantedBy = [ "multi-user.target" ];
      before = [ "nix-daemon.service" ];
      requiredBy = [ "nix-daemon.service" ];
      unitConfig.ConditionPathExists = "!${signingKey}";
      serviceConfig.Type = "oneshot";
      path = [ config.nix.package ];
      script = ''
        umask 077
        install -d -m 0700 ${stateDir}
        nix --extra-experimental-features nix-command key generate-secret --key-name ${lib.escapeShellArg cfg.signingKeyName} >${signingKey}.tmp
        mv ${signingKey}.tmp ${signingKey}
        nix --extra-experimental-features nix-command key convert-secret-to-public <${signingKey} >${stateDir}/signing.pub
        chmod 0444 ${stateDir}/signing.pub
        echo "cluster builder signing key: $(cat ${stateDir}/signing.pub)"
      '';
    };

    system.stateVersion = lib.mkDefault "26.05";
  };
}
