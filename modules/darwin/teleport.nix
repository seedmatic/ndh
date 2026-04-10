{
  config,
  pkgs,
  lib,
  catalog,
  ndh,
  ...
}:

with lib;

let
  networkCatalog = catalog.networks or { };
  cfg = config.services.teleport;
  user = config.profile.user;
  userName = user.name;
  userHome = user.home;
  hostName = config.networking.hostName or "localhost";
  # Get Tailscale hostname from config or derive from hostname using networkCatalog
  tailnetDomain =
    if networkCatalog ? tailnet && (networkCatalog.tailnet ? domain) then
      networkCatalog.tailnet.domain
    else
      ".mammoth-skate.ts.net";
  tailscaleHostname = config.services.tailscale.hostname or "${hostName}${tailnetDomain}";

  teleportConfigFile = pkgs.writeText (ndh.store.prefixedName "teleport.yaml") ''
    ---
    version: v3
    teleport:
      nodename: ${hostName}
      data_dir: ${cfg.dataDir}
      log:
        output: stderr
        severity: ${cfg.logLevel}
        format:
          output: text
      advertise_ip: ${tailscaleHostname}

    auth_service:
      enabled: ${if cfg.authServer then "true" else "false"}
      listen_addr: 0.0.0.0:3025
      cluster_name: ${cfg.clusterName}
      proxy_listener_mode: multiplex
      tokens:
        - "node:${cfg.joinToken}"

    ssh_service:
      enabled: ${if cfg.sshService then "true" else "false"}
      labels:
        env: ${cfg.environment}
        role: ${if cfg.authServer then "auth-proxy" else "node"}

    proxy_service:
      enabled: ${if cfg.proxyService then "true" else "false"}
      web_listen_addr: 0.0.0.0:${toString cfg.webPort}
      public_addr: ${tailscaleHostname}:${toString cfg.webPort}
      https_keypairs: []
      https_keypairs_reload_interval: 0s
      ${optionalString cfg.acme.enabled ''
        acme:
            email: "${cfg.acme.email}"
      ''}
  '';

  teleportFirstRunScript = pkgs.replaceVars ./teleport.d/teleport-first-run.sh {
    userName = userName;
    dataDir = cfg.dataDir;
    tctlBin = "${pkgs.teleport}/bin/tctl";
  };

  teleportActivationScript = pkgs.runCommand (ndh.store.prefixedName "teleport-post-activation.sh") { } ''
    cp ${
      pkgs.replaceVars ./teleport.d/post-activation.sh {
        dataDir = cfg.dataDir;
        xdgStateHome = xdgStateHome;
        userName = userName;
        teleportFirstRunScript = teleportFirstRunScript;
      }
    } "$out"
    chmod +x "$out"
  '';

  teleportFirstRunActivationScript = pkgs.runCommand (ndh.store.prefixedName "teleport-first-run-activation.sh") { } ''
    cp ${
      pkgs.replaceVars ./teleport.d/first-run-activation.sh {
        dataDir = cfg.dataDir;
      }
    } "$out"
    chmod +x "$out"
  '';
in
{
  options.services.teleport = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Teleport auth/proxy server on Darwin hosts (disabled by default)";
    };

    authServer = mkOption {
      type = types.bool;
      default = true;
      description = "Enable auth service (cluster authority)";
    };

    proxyService = mkOption {
      type = types.bool;
      default = true;
      description = "Enable proxy service (web UI and SSH proxy)";
    };

    sshService = mkOption {
      type = types.bool;
      default = true;
      description = "Enable SSH service (allow SSH into this host)";
    };

    clusterName = mkOption {
      type = types.str;
      default = "mammoth-skate";
      description = "Teleport cluster name";
    };

    dataDir = mkOption {
      type = types.str;
      default = "${xdgStateHome}/teleport";
      description = "Data directory for Teleport";
    };

    webPort = mkOption {
      type = types.port;
      default = 3080;
      description = "Web UI port (use 3080 to avoid needing root for 443)";
    };

    logLevel = mkOption {
      type = types.enum [
        "DEBUG"
        "INFO"
        "WARN"
        "ERROR"
      ];
      default = "INFO";
      description = "Log level";
    };

    environment = mkOption {
      type = types.str;
      default = "development";
      description = "Environment label for nodes";
    };

    joinToken = mkOption {
      type = types.str;
      default = "insecure-dev-token-change-me";
      description = "Join token for nodes (generate with: tctl tokens add --type=node)";
    };

    acme = {
      enabled = mkOption {
        type = types.bool;
        default = false;
        description = "Enable ACME for automatic TLS certificates";
      };

      email = mkOption {
        type = types.str;
        default = "stephane.lacoin@gmail.com";
        description = "Email for ACME registration";
      };
    };
  };

  config = mkIf cfg.enable {
    # Run Teleport setup scripts during postActivation so they appear and execute in the generated activate
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${teleportActivationScript}
        ${teleportFirstRunActivationScript}
        ${teleportFirstRunScript}
    '';

    # Create a launch agent to run the first-time setup
    launchd.user.agents.teleport-setup = {
      serviceConfig = {
        ProgramArguments = [ "/usr/local/bin/teleport-first-run" ];
        RunAtLoad = true;
        StandardOutPath = "${cfg.dataDir}/setup.log";
        StandardErrorPath = "${cfg.dataDir}/setup-error.log";
        KeepAlive = false;
      };
    };

    # Create wrapper scripts that set the correct data directory and config
    environment.systemPackages = [
      pkgs.teleport
      (pkgs.writeScriptBin "tctl" ''
        #!/usr/bin/env bash
        export TELEPORT_CONFIG_FILE=/etc/teleport.yaml
        export TELEPORT_HOME=${cfg.dataDir}
        exec ${pkgs.teleport}/bin/tctl --config=/etc/teleport.yaml "$@"
      '')
      (pkgs.writeScriptBin "tsh" ''
        #!/usr/bin/env bash
        export TELEPORT_HOME=${cfg.dataDir}
        exec ${pkgs.teleport}/bin/tsh --proxy=${tailscaleHostname}:${toString cfg.webPort} "$@"
      '')
    ];

    # Create a system-wide tctl configuration
    environment.etc."teleport.yaml".source = teleportConfigFile;

    launchd.daemons.teleport = {
      serviceConfig = {
        Label = "com.gravitational.teleport";
        ProgramArguments = [
          "${pkgs.teleport}/bin/teleport"
          "start"
          "--config"
          "${teleportConfigFile}"
        ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardErrorPath = "${xdgStateHome}/log/teleport.log";
        StandardOutPath = "${xdgStateHome}/log/teleport.log";
      };
    };
  };
}
