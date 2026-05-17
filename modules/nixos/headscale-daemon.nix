# Headscale bootstrap daemon — NixOS peer of
# modules/darwin/headscale-daemon.nix.  Same role model
# (primary/standby/none), same catalog-driven config, same mDNS alias
# publishing via ndh-mdns-publish.  Runs as a system-scope systemd
# service (root) with state under /var/lib/headscale.
#
# See the Darwin module's header comment for the overall bootstrap /
# takeover narrative.
{
  config,
  pkgs,
  lib,
  ndh,
  ndhSystemd,
  ...
}:

with lib;

let
  cfg = config.services.headscaleBootstrap;
  catalog = ndh.context.catalog;
  headscaleCatalog = catalog.headscale;

  serverUrl = headscaleCatalog.aliasUrl;

  tailnetCfg = catalog.netplan.tailnet;
  baseDomain = lib.removePrefix "." tailnetCfg.domain;

  stateDir = "/var/lib/headscale";
  configFile = "${stateDir}/config.yaml";

  mdnsPublish = pkgs.callPackage ../../packages/ndh-mdns-publish { };

  buildHeadscaleConfig = (import ../.common.d/headscale-daemon.d/build-config.nix) {
    inherit pkgs ndh;
  };

  # Same `extra_records` shape as the Darwin peer at
  # modules/darwin/headscale-daemon.nix — see that module for the
  # design rationale (catalog → A records → tailscaled-served, no
  # per-host dnsmasq).
  extraRecords = lib.concatLists (
    lib.mapAttrsToList (
      hostKey: hostSpec:
      map (svc: {
        name = "${svc}.${hostKey}.${baseDomain}";
        type = "A";
        value = hostSpec.ip;
      }) hostSpec.serviceNames
    ) (tailnetCfg.hosts or { })
  );

  # Headscale config as a Nix attrset; the keys map 1:1 to the
  # headscale config schema.  Rendered to YAML by the helper at
  # modules/.common.d/headscale-daemon.d/build-config.nix using yq.
  # See the Darwin peer at modules/darwin/headscale-daemon.nix for
  # the rationale comments (TLS, DERP, DNS, …).
  headscaleConfigValue = {
    server_url = serverUrl;
    listen_addr = "0.0.0.0:${toString headscaleCatalog.listenPort}";
    metrics_listen_addr = "127.0.0.1:${toString (headscaleCatalog.listenPort + 1)}";

    private_key_path = "${stateDir}/private.key";
    noise = {
      private_key_path = "${stateDir}/noise_private.key";
    };

    database = {
      type = "sqlite3";
      sqlite = {
        path = "${stateDir}/db.sqlite";
      };
    };

    policy = {
      mode = "file";
      path = "${headscaleCatalog.aclPolicyFile}";
    };

    dns = {
      magic_dns = true;
      base_domain = baseDomain;
      nameservers = {
        global = [ "1.1.1.1" "8.8.8.8" ];
      };
      extra_records = extraRecords;
    };

    log = {
      level = "info";
      format = "text";
    };

    derp = {
      server = { enabled = false; };
      urls = [ "https://controlplane.tailscale.com/derpmap/default" ];
      auto_update_enabled = true;
      update_frequency = "24h";
    };

    ephemeral_node_inactivity_timeout = "30m";
    unix_socket = "${stateDir}/headscale.sock";
    unix_socket_permission = "0770";
  };

  headscaleConfigYaml = buildHeadscaleConfig.build {
    name = "nixos-${config.networking.hostName or "host"}";
    configValue = headscaleConfigValue;
  };

  # The launcher ensures the state dir exists + symlinks the store
  # config.yaml before exec'ing headscale.  Same shape as the Darwin
  # module; the script itself is platform-agnostic.
  headscaleLauncher = pkgs.writeShellScript "headscale-bootstrap-launcher" ''
    set -euo pipefail

    STATE_DIR=${lib.escapeShellArg stateDir}
    CONFIG_LINK=${lib.escapeShellArg configFile}
    CONFIG_SRC=${headscaleConfigYaml}

    mkdir -p "$STATE_DIR"
    chmod 0750 "$STATE_DIR"

    ln -sfn "$CONFIG_SRC" "$CONFIG_LINK"

    exec ${lib.getExe pkgs.headscale} --config "$CONFIG_LINK" serve
  '';
in
{
  options.services.headscaleBootstrap = {
    role = mkOption {
      type = types.enum [
        "primary"
        "standby"
        "none"
      ];
      default = "none";
      description = ''
        This host's role in the headscale bootstrap topology.  Matches
        the Darwin peer at modules/darwin/headscale-daemon.nix; see
        there for the full semantics.

          primary — run the daemon AND publish the mDNS alias.
          standby — install material; do not run either service.
          none    — do nothing.
      '';
    };
  };

  config = mkMerge [
    # Shared setup for primary + standby: install the CLI, ensure the
    # state dir exists with correct ownership, create the headscale
    # system user so the daemon can drop privileges if we ever switch
    # to User=headscale rather than root.
    (mkIf (cfg.role != "none") {
      environment.systemPackages = [
        pkgs.headscale
        mdnsPublish
      ];

      # Dedicated system user so a future User= directive in the
      # systemd unit can drop privileges; right now the daemon runs
      # as root to keep parity with the Darwin user-scope launchd
      # shape, but the user exists so the migration is a single flag.
      users.users.headscale = {
        isSystemUser = true;
        group = "headscale";
        home = stateDir;
        createHome = false;
      };
      users.groups.headscale = { };

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0750 headscale headscale - -"
      ];
    })

    # Primary-only: the two systemd units that together own the alias
    # identity (daemon + mdns publisher).  Same exactly-one invariant
    # as the Darwin module.
    (mkIf (cfg.role == "primary") {
      systemd.services.${ndhSystemd.mkUnitName "headscale-bootstrap"} = {
        description = "Headscale bootstrap control-plane (catalog-driven, alias-addressed)";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "sops-install-secrets.service"
        ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "exec";
          ExecStart = "${headscaleLauncher}";
          Restart = "on-failure";
          RestartSec = "5s";
          StandardOutput = "journal";
          StandardError = "journal";
          # State dir is root-owned per the tmpfiles rule above; the
          # daemon runs as root to write there and to open sockets.
          # Switch to User=headscale once key-path permissions are
          # confirmed to allow unprivileged writes.
          User = "root";
          Group = "root";
          # Hardening knobs that do not break headscale's needs.
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ stateDir ];
          NoNewPrivileges = true;
        };
      };

      systemd.services.${ndhSystemd.mkUnitName "headscale-mdns-publish"} = {
        description = "Publish mDNS alias for the current headscale primary";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "exec";
          ExecStart = "${lib.getExe mdnsPublish} --name=${headscaleCatalog.serviceName} --host=${lib.escapeShellArg (lib.removeSuffix ".local" headscaleCatalog.aliasName)} --port=${toString headscaleCatalog.listenPort}";
          Restart = "on-failure";
          RestartSec = "5s";
          StandardOutput = "journal";
          StandardError = "journal";
          # The publisher binds UDP 5353 via multicast; no privileged
          # writes needed.  Run as headscale:headscale so the two
          # units share an identity for audit grepping.
          User = "headscale";
          Group = "headscale";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
        };
      };

      # Open the headscale port for clients joining the tailnet.
      networking.firewall.allowedTCPPorts = [ headscaleCatalog.listenPort ];
      # mDNS (UDP 5353) is typically open on lan interfaces already
      # via the avahi module; no extra rule needed here.
    })
  ];
}
