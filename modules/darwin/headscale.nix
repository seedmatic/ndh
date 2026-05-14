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

  # Darwin hosts register with the `darwin` kind
  # (tag:console,tag:darwin).  Fixed at the platform level rather than reading
  # back from `tailnet.headscale.auth.*.enable` to keep module eval
  # free of self-reference cycles — same shape as the NixOS client.
  # `cfg.authKeyFile` remains as an out-of-band override for manual
  # bootstrap / test harnesses.
  activeAuthKind = "darwin";
  effectiveAuthKeyFile =
    if cfg.authKeyFile != null then
      cfg.authKeyFile
    else
      tailnet.headscale.auth.${activeAuthKind}.path;

  tagsCsv = concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags);

  headscaleActivationScript = ndh.store.runCommand "headscale-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./headscale-client.d/post-activation.sh {
        nixBashTrampoline = nixBashTrampoline;
        enableSSH = if cfg.enableSSH then "true" else "false";
        acceptRoutes = if cfg.acceptRoutes then "true" else "false";
        serverUrl = cfg.serverUrl;
        hostname = cfg.hostname;
        # Empty string => interactive-login fallback (hook won't
        # autojoin).  Otherwise = absolute path of the sops-materialised
        # authkey the common tailnet module places under
        # /run/secrets/nix-darwin-home/tailnet.headscale.auth.
        authKeyFile = if effectiveAuthKeyFile != null then effectiveAuthKeyFile else "";
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

          # Always logout first so a stale node key (e.g. after a
          # headscale DB wipe or key rotation) doesn't leak into the
          # register attempt and flip tailscale into its "force HTTPS:443"
          # fallback that our plain-HTTP daemon can't satisfy.
          tailscale logout >/dev/null 2>&1 || true

          # `--timeout=45s` caps tailscaled's wait for Running — without
          # it a missing daemon blocks forever; with it we fail fast and
          # the operator can retry.
          CMD="tailscale up --timeout=45s --login-server=${cfg.serverUrl} --hostname=${cfg.hostname}"
          ${optionalString cfg.enableSSH ''CMD="$CMD --ssh"''}
          ${optionalString cfg.acceptRoutes ''CMD="$CMD --accept-routes"''}

          # Headscale v2 rejects `--advertise-tags` on preauth-key
          # registrations (tags are carried by the key itself).  Only
          # append the flag when falling back to interactive login —
          # i.e. when no auth-key file is available.
          AUTH_KEY_FILE="${if effectiveAuthKeyFile != null then effectiveAuthKeyFile else ""}"
          if [ -n "$AUTH_KEY_FILE" ] && [ -r "$AUTH_KEY_FILE" ]; then
            CMD="$CMD --authkey=$(tr -d '[:space:]' < "$AUTH_KEY_FILE")"
          else
            ${optionalString (cfg.tags != [ ]) ''CMD="$CMD --advertise-tags=${tagsCsv}"''}
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

  ]);
}
