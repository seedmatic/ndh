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

  # Shared lib used by both consumers (post-activation hook +
  # `hs-connect`).  Inlined verbatim into each via pkgs.replaceVars
  # so writeShellApplication's shellcheck pass can see the whole
  # composed script — same pattern the `hs` admin CLI uses for
  # modules/darwin/headscale-tools/hs-lib.sh.
  hsClientLibText = builtins.readFile ./headscale-client.d/lib.sh;

  # Common token replacements for both consumers.  authKeyFile is
  # empty-string when no key is available (sops not yet materialised
  # / fresh laptop) — the lib's reconcile helper handles the empty
  # case by warning and skipping.
  hsClientReplaceVars = {
    nixBashTrampoline = nixBashTrampoline;
    HEADSCALE_CLIENT_LIB_INLINE = hsClientLibText;
    enableSSH = if cfg.enableSSH then "true" else "false";
    acceptRoutes = if cfg.acceptRoutes then "true" else "false";
    serverUrl = cfg.serverUrl;
    hostname = cfg.hostname;
    authKeyFile = if effectiveAuthKeyFile != null then effectiveAuthKeyFile else "";
  };

  headscaleActivationScript = ndh.store.runCommand "headscale-post-activation.sh" { } ''
    cp ${pkgs.replaceVars ./headscale-client.d/post-activation.sh hsClientReplaceVars} "$out"
    chmod +x "$out"
  '';

  # `hs-connect` — operator-facing reconcile wrapper.  writeShellApplication
  # gives us shellcheck-at-build-time + a curated runtimeInputs PATH so the
  # script can rely on `tailscale`, coreutils, etc. without thinking about
  # the host shell's PATH.
  hsConnectBin = pkgs.writeShellApplication {
    name = "hs-connect";
    text = builtins.readFile (
      pkgs.replaceVars ./headscale-client.d/hs-connect.sh hsClientReplaceVars
    );
    runtimeInputs = with pkgs; [
      tailscale
      coreutils
    ];
  };
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
        hsConnectBin
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
