# Headscale client on Darwin.  Consumes the shared tailnet-secret
# schema declared in [modules/.common.d/tailnet.nix] — enable the
# relevant secrets via `tailnet.headscale.auth.enable` /
# `tailnet.headscale.api.enable` and the runtime paths materialise
# automatically at /run/secrets/nix-darwin-home/tailnet.headscale.*.
#
# Two operator-facing behaviours:
#   hs-connect  — idempotent `tailscale up` against the configured
#                 headscale server.  If `tailnet.headscale.auth` is
#                 materialised, registration is non-interactive.
#   hs          — `headscale` admin CLI wrapper.  Sources
#                 HEADSCALE_CLI_ADDRESS + HEADSCALE_CLI_API_KEY from
#                 the sops-materialised api secret at invocation time.
#                 Only provisioned when `tailnet.headscale.api` is
#                 enabled (a remote-admin scenario — the primary host
#                 talks to its daemon via the unix socket and has no
#                 use for the api key).
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
  tailnet = config.tailnet;
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  defaultHostname = config.networking.hostName or "localhost";

  # When the common module has materialised the auth secret, derive
  # the runtime path from there.  `cfg.authKeyFile` remains as an
  # explicit out-of-band override for manual bootstrap / tests.
  effectiveAuthKeyFile =
    if cfg.authKeyFile != null then
      cfg.authKeyFile
    else if tailnet.headscale.auth.enable then
      tailnet.headscale.auth.path
    else
      null;

  tagsCsv = concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags);

  headscaleActivationScript = ndh.store.runCommand "headscale-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./headscale-client.d/post-activation.sh {
        nixBashTrampoline = nixBashTrampoline;
        enableSSH = if cfg.enableSSH then "true" else "false";
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

    authKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Explicit override for the auth-key file path.  Normally left
        null — the module derives the path from
        `config.tailnet.headscale.auth.path` when
        `tailnet.headscale.auth.enable` is true.  Set this only when
        the key is provisioned out-of-band (e.g. manual bootstrap or
        a test harness).
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      environment.shellAliases = {
        hs-status = "tailscale status";
        hs-netcheck = "tailscale netcheck";
      };

      environment.systemPackages = [
        pkgs.tailscale
        (pkgs.writeScriptBin "hs-connect" ''
          #!/usr/bin/env bash
          set -e

          if tailscale status >/dev/null 2>&1; then
            echo "Already connected to Headscale"
            tailscale status
            exit 0
          fi

          CMD="tailscale up --login-server=${cfg.serverUrl} --hostname=${cfg.hostname}"
          ${optionalString cfg.enableSSH ''CMD="$CMD --ssh"''}
          ${optionalString cfg.acceptRoutes ''CMD="$CMD --accept-routes"''}
          ${optionalString (cfg.tags != [ ]) ''CMD="$CMD --advertise-tags=${tagsCsv}"''}

          AUTH_KEY_FILE="${if effectiveAuthKeyFile != null then effectiveAuthKeyFile else ""}"
          if [ -n "$AUTH_KEY_FILE" ] && [ -r "$AUTH_KEY_FILE" ]; then
            CMD="$CMD --authkey=$(tr -d '[:space:]' < "$AUTH_KEY_FILE")"
          fi

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

      system.activationScripts.postActivation.text = mkAfter ''
        ${headscaleActivationScript}
      '';
    }

    # `hs` admin wrapper.  Two invocation modes:
    #
    #   - Local (primary host): when the daemon's config file exists
    #     on disk at ~/.config/headscale/config.yaml, call the CLI
    #     with `-c <path>` and let it talk to the daemon via the
    #     unix socket (authenticated by file permissions).  No api
    #     key needed; in fact headscale doesn't expose remote gRPC
    #     at all unless TLS or `grpc_allow_insecure` is explicitly
    #     turned on in the server config.
    #
    #   - Remote (any other host): source HEADSCALE_CLI_* from the
    #     sops-materialised api secret at invocation time and let
    #     the CLI hit the daemon over gRPC.  The cleartext key
    #     never persists in the shell env or history.
    #
    # Only provisioned when the operator opted into the api secret
    # on this host.  See the shared schema in
    # [modules/.common.d/tailnet.nix].
    (mkIf tailnet.headscale.api.enable {
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "hs" ''
          set -euo pipefail

          LOCAL_CONFIG="$HOME/.config/headscale/config.yaml"
          if [ -r "$LOCAL_CONFIG" ]; then
            exec headscale -c "$LOCAL_CONFIG" "$@"
          fi

          API_KEY_FILE=${escapeShellArg tailnet.headscale.api.path}
          if [ ! -r "$API_KEY_FILE" ]; then
            echo "[hs] no local headscale config and api key not readable at $API_KEY_FILE" >&2
            exit 1
          fi
          # `HEADSCALE_CLI_ADDRESS` must be a gRPC host:port, not a
          # URL.  The catalog.headscale.aliasUrl is HTTP-only today;
          # callers running `hs` remotely need the daemon to have
          # `grpc_allow_insecure: true` + `grpc_listen_addr` set.  We
          # derive a sane host:port from the serverUrl when possible;
          # otherwise the operator overrides via HEADSCALE_CLI_ADDRESS.
          : "''${HEADSCALE_CLI_ADDRESS:=${cfg.hostname}:50443}"
          export HEADSCALE_CLI_ADDRESS
          export HEADSCALE_CLI_API_KEY="$(tr -d '[:space:]' < "$API_KEY_FILE")"
          exec headscale "$@"
        '')
      ];
    })
  ]);
}
