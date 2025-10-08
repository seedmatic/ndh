{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.teleport;
  user = config.profile.user;
  userName = user.name;
  userHome = user.home;
  hostName = config.networking.hostName or "localhost";
  
  # XDG directories - use standard paths directly
  xdgStateHome = "${userHome}/.local/state";
  
  # Get Tailscale hostname from config or derive from hostname
  tailscaleHostname = config.services.tailscale.hostname or "${hostName}.mammoth-skate.ts.net";
  
  teleportConfigFile = pkgs.writeText "teleport.yaml" ''
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
in
{
  options.services.teleport = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Teleport auth/proxy server on all Darwin hosts";
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
      type = types.enum [ "DEBUG" "INFO" "WARN" "ERROR" ];
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
    # Ensure XDG directories exist and set permissions
    system.activationScripts.postActivation.text = ''
      : "Setting up Teleport directories and first-run script"
      
      # Create required directories
      mkdir -p ${cfg.dataDir}
      mkdir -p ${xdgStateHome}/log
      
      # Set permissions
      chown -R root:admin ${cfg.dataDir}
      chmod -R g+rwX ${cfg.dataDir}
      chmod 770 ${cfg.dataDir}
      
      chown ${userName}:staff ${xdgStateHome}/log
      
      # Create first-run script in a system location
      mkdir -p /usr/local/bin
      if [ ! -f "/usr/local/bin/teleport-first-run" ]; then
        cat > /usr/local/bin/teleport-first-run <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Only run for the primary user
if [ "$(whoami)" != "${userName}" ]; then
  exit 0
fi

: "Waiting for Teleport to start"
for i in {1..30}; do
  if ${pkgs.teleport}/bin/tctl status &>/dev/null; then
    break
  fi
  sleep 1
done

# Check if setup is already done
if [ -f "${cfg.dataDir}/.initial-setup-done" ]; then
  exit 0
fi

: "Importing RBAC roles"
${pkgs.teleport}/bin/tctl create -f /etc/teleport/roles.yaml 2>/dev/null || true

: "Getting all users in admin or wheel group"
ADMIN_USERS=$(dscl . -read /Groups/admin GroupMembership 2>/dev/null | sed 's/GroupMembership: //' || echo "")
WHEEL_USERS=$(dscl . -read /Groups/wheel GroupMembership 2>/dev/null | sed 's/GroupMembership: //' || echo "")
ALL_ADMINS=$(echo "$ADMIN_USERS $WHEEL_USERS" | tr ' ' '\n' | sort -u | grep -v '^$')

: "Creating Teleport users for admin group members"
for user in $ALL_ADMINS; do
  : "Checking user: $user"
  if ! ${pkgs.teleport}/bin/tctl users ls | grep -q "^$user"; then
    : "Creating Teleport user for: $user"
    ${pkgs.teleport}/bin/tctl users add "$user" --roles=admin --logins="$user",root
    echo ""
    echo "✅ User '$user' created! Use the signup link above to set password."
    echo ""
  fi
done

touch "${cfg.dataDir}/.initial-setup-done"
echo "✅ Teleport setup complete!"
EOF
        chmod +x /usr/local/bin/teleport-first-run
      fi
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
    
    # Ensure the first-run script is run as the current user
    system.activationScripts.teleportFirstRun = ''
      if [ ! -f "${cfg.dataDir}/.initial-setup-done" ] && [ -x "$HOME/.local/bin/teleport-first-run" ]; then
        echo "Running Teleport first-time setup..."
        sudo -u $USER $HOME/.local/bin/teleport-first-run || true
      fi
    '';
    
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

