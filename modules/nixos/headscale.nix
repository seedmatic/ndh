{
  config,
  pkgs,
  lib,
  ndhSystemd,
  ...
}:

with lib;

let
  cfg = config.networking.headscale;
  tailnet = config.tailnet;
  defaultHostname = config.networking.hostName;
  tailscaleAutoconnectUnitName = ndhSystemd.mkUnitName "tailscaled-autoconnect";
  contributedTargetName = ndhSystemd.contributedTargetName;

  # NixOS guests always register with the `nixos` kind
  # (tag:headless,tag:nixos).  Fixed at the platform level rather than reading back
  # from `tailnet.headscale.auth.*.enable` — the latter creates an
  # infinite-recursion cycle because we *also* set the owner override
  # on that same attribute below, and module evaluation can't reach a
  # fixed point when a config read feeds a config write on the same
  # option.  `cfg.authKeyFile` remains as an out-of-band override for
  # manual bootstrap / test harnesses.
  activeAuthKind = "nixos";
  effectiveAuthKeyFile =
    if cfg.authKeyFile != null then
      cfg.authKeyFile
    else
      tailnet.headscale.auth.${activeAuthKind}.path;
in
{
  options.networking.headscale = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Headscale client (Tailscale connected to Headscale)";
    };

    serverUrl = mkOption {
      type = types.str;
      example = "https://headscale.example.com";
      description = "URL of the Headscale server";
    };

    authKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to file containing the Headscale auth key";
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
        "server"
        "production"
      ];
      description = "Tags to apply to this node";
    };

    acceptRoutes = mkOption {
      type = types.bool;
      default = false;
      description = "Accept routes from other nodes (useful if you have gateways)";
    };
  };

  config = mkIf cfg.enable {
    # `tailscaled` is root-run on NixOS; override the common module's
    # default (profile user) on the active per-kind auth slot so
    # sops-install-secrets materialises the file as root at 0400.
    # Without this, the profile user owns the file and the root-run
    # unit can't read it.
    tailnet.headscale.auth.${activeAuthKind} = {
      owner = "root";
      mode = "0400";
    };

    # Install Tailscale (client compatible with Headscale).  We DO NOT
    # set `authKeyFile` here: the nixpkgs tailscale module generates
    # its own `tailscaled-autoconnect.service` when that option is
    # non-null, and that generated unit has no ordering against
    # `sops-install-secrets` — on boot it races with sops, usually
    # losing and failing with "No such file or directory" on the
    # secret path.  The prefixed unit
    # `io-nxmatic-nix-darwin-home-tailscaled-autoconnect` below is
    # the race-safe equivalent that owns the registration flow for
    # the fleet.  Keep `extraUpFlags` here so that a manual
    # `tailscale up` still gets the right defaults, but registration
    # lives in our unit.
    services.tailscale = {
      enable = true;
      extraUpFlags =
        let
          sshFlag = if cfg.enableSSH then [ "--ssh" ] else [ ];
          tagFlags =
            if (cfg.tags != [ ]) then
              [ "--advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}" ]
            else
              [ ];
          acceptRoutesFlag = if cfg.acceptRoutes then [ "--accept-routes" ] else [ ];
        in
        [
          "--login-server=${cfg.serverUrl}"
          "--hostname=${cfg.hostname}"
        ]
        ++ sshFlag
        ++ tagFlags
        ++ acceptRoutesFlag;
    };

    # Trust Tailscale interface
    networking.firewall.trustedInterfaces = [ "tailscale0" ];

    # Ensure Tailscale connects at boot.  Order strictly after
    # sops-install-secrets so the auth-key file exists when the unit
    # starts — early boots otherwise race and the first attempt fails
    # with "cat: /run/secrets/.../tailnet.headscale.auth: No such file
    # or directory", leaving the node unregistered until a manual
    # `systemctl restart`.  ConditionPathExists belts-and-braces the
    # gating for hosts that disabled the sops secret on purpose.
    systemd.services.${tailscaleAutoconnectUnitName} = {
      after = [
        "tailscaled.service"
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [
        "tailscaled.service"
        "network-online.target"
      ];
      requires = [ "sops-install-secrets.service" ];
      wantedBy = [ contributedTargetName ];
      unitConfig = lib.mkIf (effectiveAuthKeyFile != null) {
        ConditionPathExists = effectiveAuthKeyFile;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        wait_for_tailscaled() {
          for i in $(seq 1 30); do
            # "tailscale version" talks to the daemon without requiring login
            if ${pkgs.tailscale}/bin/tailscale version >/dev/null 2>&1; then
              return 0
            fi
            sleep 1
          done
          echo "tailscaled not ready after 30s" >&2
          return 1
        }

        wait_for_tailscaled || exit 0

        # If already connected, we're done
        if ${pkgs.tailscale}/bin/tailscale status >/dev/null 2>&1; then
          echo "Already connected to Headscale"
          exit 0
        fi

        auth_key_file="${if effectiveAuthKeyFile != null then effectiveAuthKeyFile else ""}"

        if [ -z "$auth_key_file" ] || [ ! -f "$auth_key_file" ]; then
          echo "No auth key available; skipping autoconnect"
          exit 0
        fi

        # Headscale v2 rejects `--advertise-tags` on preauth-key
        # registrations — tags come from the key itself, not the client
        # request (see hscontrol/state/state.go:1660 in
        # juanfont/headscale).  The earlier `cfg.tags` wiring becomes
        # informational only: it's applied to non-authkey flows
        # (interactive login) but must be omitted here.  The preauth
        # key our `hs` admin CLI minted carries the full operator+
        # service+{darwin,nixos,incus,rke2} tagset; every client
        # inherits that on registration.
        #
        # IMPORTANT: do NOT call `tailscale logout` here.  An earlier
        # version of this unit did, on the theory that "always start
        # from a known-logged-out state" was harmless.  It is not.
        # `tailscale logout` sends a RegisterRequest with `Expiry=past`
        # to the server; headscale's auth.go:194-225 handleLogout()
        # treats any past-expiry register as a logout, and for non-
        # ephemeral nodes it writes that past expiry into the DB record
        # via SetNodeExpiry().  On the next boot, the same machinekey
        # presents → server finds the existing node, sees Expiry in the
        # past, and short-circuits in auth.go:169-181 with
        # `NodeKeyExpired: true, MachineAuthorized: false` — the
        # incoming preauth key in the request is never even consulted.
        # The client then loops forever ("regen=true but server says
        # NodeKeyExpired") until an operator runs `headscale nodes
        # delete <id>`.  Removing the logout call leaves any prior
        # successful registration intact across reboots; `tailscale up
        # --reset --authkey=...` below is sufficient to clear local
        # stale prefs without poisoning the server-side record.

        # `--reset` clears any stale prefs from prior (possibly failed)
        # registration attempts — e.g. the `--advertise-tags` residue
        # from before the v2 semantics flip, which otherwise makes
        # `tailscale up` refuse to proceed because the flag set
        # differs from the current state's "non-default" prefs.  Safe
        # to keep permanently: this unit is the authoritative
        # registration flow on this host.
        # `--timeout=45s` caps tailscaled's wait for Running — without
        # it a missing headscale daemon blocks the unit indefinitely;
        # with it, a failing activation fails fast and systemd retries
        # are cheap.
        ${pkgs.tailscale}/bin/tailscale up \
          --timeout=45s \
          --reset \
          --login-server=${cfg.serverUrl} \
          --authkey="$(cat "$auth_key_file")" \
          --hostname=${cfg.hostname} \
          ${optionalString cfg.enableSSH "--ssh"} \
          ${optionalString cfg.acceptRoutes "--accept-routes"} \
          || {
            echo "tailscale up failed" >&2
            exit 1
          }

        exit 0
      '';
    };

    # Add useful management commands
    environment.systemPackages = with pkgs; [
      tailscale
      (writeScriptBin "hs-status" ''
        #!/usr/bin/env bash
        echo "=== Headscale Connection Status ==="
        ${pkgs.tailscale}/bin/tailscale status
        echo ""
        echo "=== Network Check ==="
        ${pkgs.tailscale}/bin/tailscale netcheck
      '')
      (writeScriptBin "hs-ssh" ''
        #!/usr/bin/env bash
        if [ -z "$1" ]; then
          echo "Usage: hs-ssh <hostname>"
          echo "Available hosts:"
          ${pkgs.tailscale}/bin/tailscale status --json | ${pkgs.jq}/bin/jq -r '.Peer[].HostName'
          exit 1
        fi
        ${pkgs.tailscale}/bin/tailscale ssh "$1"
      '')
    ];
  };
}
