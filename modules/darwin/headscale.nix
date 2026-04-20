{
  config,
  pkgs,
  lib,
  ndh,
  ...
}:

with lib;

let
  cfg = config.networking.headscale;
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  defaultHostname = config.networking.hostName or "localhost";
  loggerScript = config.nixBashLogger.script;

  headscaleActivationScript = ndh.store.runCommand "headscale-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./headscale-client.d/post-activation.sh {
        nixBashTrampoline = nixBashTrampoline;
      }
    } "$out"
    chmod +x "$out"
  '';
in
{
  options.networking.headscale = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Headscale client (Tailscale connected to Headscale) on Darwin";
    };

    serverUrl = mkOption {
      type = types.str;
      example = "https://headscale.example.com";
      description = "URL of the Headscale server";
    };

    hostname = mkOption {
      type = types.str;
      default = defaultHostname;
      description = "Hostname to advertise";
    };

    enableSSH = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Tailscale SSH";
    };

    tags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "darwin"
        "laptop"
      ];
      description = "Tags to apply to this node";
    };

    acceptRoutes = mkOption {
      type = types.bool;
      default = false;
      description = "Accept routes from other nodes";
    };
  };

  config = mkIf cfg.enable {
    # Create helpful aliases and scripts
    environment.shellAliases = {
      hs-status = "tailscale status";
      hs-netcheck = "tailscale netcheck";
    };

    # Install Tailscale and helper scripts
    environment.systemPackages = [
      pkgs.tailscale
      (pkgs.writeScriptBin "hs-connect" ''
        #!/usr/bin/env bash
        set -e

        # Check if already connected
        if tailscale status >/dev/null 2>&1; then
          echo "Already connected to Headscale"
          tailscale status
          exit 0
        fi

        # Build the connection command
        CMD="tailscale up --login-server=${cfg.serverUrl} --hostname=${cfg.hostname}"

        ${optionalString cfg.enableSSH ''CMD="$CMD --ssh"''}
        ${optionalString cfg.acceptRoutes ''CMD="$CMD --accept-routes"''}
        ${optionalString (cfg.tags != [ ])
          ''CMD="$CMD --advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}"''
        }

        # Prompt for authentication
        echo "Connecting to Headscale at ${cfg.serverUrl}..."
        echo "Running: $CMD"
        eval "$CMD"
      '')
      (pkgs.writeScriptBin "hs-ssh" ''
        #!/usr/bin/env bash
        if [ -z "$1" ]; then
          echo "Usage: hs-ssh <hostname>"
          echo "Available hosts:"
          tailscale status --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.Peer[].HostName' || tailscale status
          exit 1
        fi
        tailscale ssh "$@"
      '')
      (pkgs.writeScriptBin "hs-disconnect" ''
        #!/usr/bin/env bash
        tailscale down
        echo "Disconnected from Headscale"
      '')
    ];

    # Note for the user
    system.activationScripts.postActivation.text = mkAfter ''
      ${headscaleActivationScript}
    '';
  };
}
