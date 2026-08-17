# Headscale bootstrap daemon — runs as a user LaunchAgent on each
# operator Darwin host.  Owns the tailnet control-plane during the
# bootstrap phase, before the rke2-hosted production instance exists.
#
# State lives under `~/Library/Application Support/Headscale/`, matching
# macOS conventions for user daemons (Time Machine-backed up,
# sandbox-friendly).  The binary comes from pkgs.headscale.
#
# Policy is pinned to the Nix-store copy of
# `catalog.tailnet.aclPolicyFile`; reloading the daemon re-reads it,
# so editing the ACL + running `darwin-rebuild switch` is the full
# apply cycle — no separate `headscale policy set` post-activation
# hook needed.
#
# Clients authenticate via pre-auth keys.  Keys are created on first
# use with `headscale preauthkeys create --user <user>@`; they are NOT
# provisioned by this module (one-time bootstrap concern).  Once a
# client registers, re-registrations use the stored node key.
#
# NOTE: Headscale policy v2 requires usernames with a trailing `@`
# suffix (e.g., `nxmatic@`) to disambiguate plain usernames from
# OIDC email identifiers.  See catalog/headscale/acl.hujson.
{
  config,
  pkgs,
  lib,
  ndh,
  self,
  ...
}:

with lib;

let
  cfg = config.services.headscaleBootstrap;
  catalog = ndh.context.catalog;
  headscaleCatalog = catalog.tailnet.headscale;
  hostName = config.networking.hostName or "localhost";

  # Shared headscale derivation (pinned to 0.28.x via
  # nixpkgs-unstable) — same binary the `hs` admin CLI uses, so
  # daemon and client can't drift in version.  Defined in
  # modules/.common.d/headscale-pkg.nix.
  headscalePkg = config.ndh.headscalePkg;

  # Clients resolve `aliasName` (= `mammoth-skate.duckdns.org`) over
  # public DNS to the WAN address the Bbox port-forwards to bioskop:41841.
  # The daemon itself is told to issue certificates and registration
  # URLs under that same alias, so a standby→primary flip on a
  # different host is transparent at the tailnet level (the WAN port-
  # forward target moves; the alias does not).
  serverUrl = headscaleCatalog.aliasUrl;

  tailnetCfg = catalog.netplan.tailnet;
  baseDomain = lib.removePrefix "." tailnetCfg.domain;

  # TLS leaf + private extracted by the ssh-keys enrichment pipeline
  # from keys.yaml's headscale-tls-server entry.
  #
  # Private: OpenSSH's native Ed25519 format is what ssh-keygen +
  # the enrichment pipeline produce by default, but Go's crypto/tls
  # parser (what headscale uses) rejects that shape with "failed to
  # parse private key".  The extractor converts the OpenSSH private
  # into PKCS8 PEM next to it (<basename>.pem) — that's the file we
  # feed to tls_key_path.  See ssh-extract-keys.sh's "Emit PKCS8 PEM"
  # block for the conversion.  The OpenSSH file stays in place for
  # callers that still want SSH semantics.
  #
  # Cert: PEM x509 emitted by step-cli in the enrichment pipeline,
  # lands next to the private with a `.crt` suffix (see
  # modules/home-manager/ssh-key.d/ssh-extract-keys.split-exp.yq).
  tlsKeyPath = "${config.sshPaths.secretsKeysDir}/headscale-tls-server.pem";
  tlsCertPath = "${config.sshPaths.secretsKeysDir}/headscale-tls-server.crt";

  # XDG split:
  #   config at `~/.config/headscale/`        (XDG_CONFIG_HOME)
  #   state  at `~/.local/state/headscale/`  (XDG_STATE_HOME)
  #
  # Per the XDG Base Directory spec, `$XDG_DATA_HOME` (`~/.local/share/`)
  # is for user-specific *data files* (sources, installed assets) while
  # `$XDG_STATE_HOME` (`~/.local/state/`) is for "state data that is not
  # important enough to be configured or is likely to be modified
  # automatically" — which is exactly what the sqlite DB, noise private
  # key, and unix socket are.  Earlier revisions of this module placed
  # the state under `~/.local/share/`, which technically worked but mis-
  # categorised it as data.  This rename is ops-safe: operators who
  # reset the headscale DB (e.g. during the bootstrap ceremony or a key
  # rotation) now won't leak confusion about "which dir is the real
  # state?" across the two profile-home subtrees.
  #
  # Sidesteps the macOS-native `~/Library/Application Support/Headscale/`
  # path entirely — that space-containing path trips tools that split
  # their arguments on whitespace (godns had the same issue; see
  # [ddns.nix]).
  homeDir = config.users.users.${config.system.primaryUser}.home;
  configDir = "${homeDir}/.config/headscale";
  dataDir = "${homeDir}/.local/state/headscale";
  configFile = "${configDir}/config.yaml";

  buildHeadscaleConfig = (import ../.common.d/headscale-daemon.d/build-config.nix) {
    inherit pkgs ndh;
  };

  # Render catalog.netplan.tailnet.hosts into the list shape expected
  # by headscale's `dns.extra_records`.  Each (host, serviceName) pair
  # becomes one CNAME entry like
  #   rdp.bioskop.mammoth-skate.ts.net  CNAME  bioskop.mammoth-skate.ts.net
  # Tailscaled (patched, see overlays/tailscale.nix) chases the chain
  # locally; MagicDNS resolves the bare-host name to its current
  # tailnet IP at the end of the chain — no hardcoded IPs anywhere
  # in this flake.
  extraRecords = lib.concatLists (
    lib.mapAttrsToList (
      hostKey: hostSpec:
      map (svc: {
        name = "${svc}.${hostKey}.${baseDomain}";
        type = "CNAME";
        value = "${hostKey}.${baseDomain}";
      }) hostSpec.serviceNames
    ) (tailnetCfg.hosts or { })
  );

  # Headscale config.yaml.  Values shaped from the catalog and the
  # platform-specific paths.  Rationale comments live in this module
  # (the rendered YAML is generated and not meant to be read for
  # design context).  Everything pinned to the state dir so
  # re-activation doesn't relocate running state.  `policy.path`
  # resolves to the Nix store — the file is a symlink target into the
  # flake closure, immutable per generation.
  #
  # TLS notes (server.tls_cert_path/tls_key_path below):
  #   - The cert is a `mammoth-skate`-signed x509 leaf carrying the
  #     DuckDNS domain (mammoth-skate.duckdns.org) as its SAN.  Clients
  #     trust it via the CA cert committed at
  #     `authorities.mammoth-skate.ca_crt` in keys.yaml, installed into
  #     each client's system trust store by the client module.
  #   - TLS is required because modern tailscale clients force the
  #     Noise upgrade onto HTTPS:443 after any failed plain-HTTP
  #     attempt (control/controlhttp/client.go's
  #     LastNoiseDialWasRecent heuristic), and because the embedded
  #     DERP relay only speaks HTTPS.
  #   - Private key is PKCS8 PEM (Go's crypto/tls rejects OpenSSH
  #     Ed25519); the extractor converts the OpenSSH private into
  #     PKCS8 alongside it.  See ssh-extract-keys.sh.
  #
  # DERP (relays): use Tailscale's public DERP network instead of
  # self-hosted.  Direct connections via STUN/NAT traversal are still
  # preferred; DERP only activates as fallback.  The embedded DERP
  # server stays disabled, saving the TLS/port complexity.
  #
  # DNS: structured service names (rdp.bioskop, ssh-host.nikopol,
  # headscale.bioskop, …) come from `extraRecords` above; tailscaled
  # answers them directly from the MapResponse-pushed list with no
  # per-host DNS daemon involved.
  headscaleConfigValue = {
    server_url = serverUrl;
    listen_addr = "0.0.0.0:${toString headscaleCatalog.listenPort}";

    tls_cert_path = tlsCertPath;
    tls_key_path = tlsKeyPath;

    metrics_listen_addr = "127.0.0.1:${toString (headscaleCatalog.listenPort + 1)}";

    prefixes = {
      v4 = catalog.netplan.tailnet.cidr;
      v6 = "fd7a:115c:a1e0::/48";
      allocation = "sequential";
    };

    private_key_path = "${dataDir}/private.key";
    noise = {
      private_key_path = "${dataDir}/noise_private.key";
    };

    database = {
      type = "sqlite3";
      sqlite = {
        path = "${dataDir}/db.sqlite";
      };
    };

    policy = {
      mode = "file";
      path = "${catalog.tailnet.aclPolicyFile}";
    };

    dns = {
      magic_dns = true;
      base_domain = baseDomain;
      nameservers = {
        global = [
          "1.1.1.1"
          "8.8.8.8"
        ];
      };
      extra_records = extraRecords;
    };

    log = {
      level = "info";
      format = "text";
    };

    derp = {
      server = {
        enabled = false;
      };
      urls = [ "https://controlplane.tailscale.com/derpmap/default" ];
      paths = [ ];
      auto_update_enabled = true;
      update_frequency = "24h";
    };

    ephemeral_node_inactivity_timeout = "30m";
    unix_socket = "${dataDir}/headscale.sock";
    unix_socket_permission = "0770";
  };

  headscaleConfigYaml = buildHeadscaleConfig.build {
    name = "darwin-${hostName}";
    configValue = headscaleConfigValue;
  };

  # Thin wrapper that ensures config + data dirs exist + symlinks the
  # Nix-store config.yaml into the config dir before exec'ing headscale
  # serve.  Stdout+stderr piped through `logger` into the macOS unified
  # log under the `headscale-bootstrap` tag so inspection is
  # `log show --predicate 'process == "logger"' --last 5m` rather than
  # chasing scattered ~/Library/Logs files.
  headscaleLauncher = pkgs.writeShellScript "headscale-bootstrap-launcher" ''
    set -euo pipefail
    exec > >(/usr/bin/logger -t headscale-bootstrap) 2>&1

    CONFIG_DIR=${lib.escapeShellArg configDir}
    DATA_DIR=${lib.escapeShellArg dataDir}
    CONFIG_LINK=${lib.escapeShellArg configFile}
    CONFIG_SRC=${headscaleConfigYaml}

    mkdir -p "$CONFIG_DIR" "$DATA_DIR"
    chmod 0700 "$DATA_DIR"

    # Symlink so a config edit (via darwin-rebuild switch) is picked up
    # on next daemon restart without copy semantics.  Headscale doesn't
    # care whether the path is a symlink.
    ln -sfn "$CONFIG_SRC" "$CONFIG_LINK"

    exec ${lib.getExe headscalePkg} --config "$CONFIG_LINK" serve
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
        This host's role in the headscale bootstrap topology.

          primary — run the daemon as the fleet's headscale instance.
                    Clients reach the daemon via the WAN-facing
                    `mammoth-skate.duckdns.org:41841` alias (Bbox port-
                    forwarded to the primary's bioskop tcp/41841).
                    Exactly one host should be primary at a time.
          standby — install the headscale CLI + config but do NOT run
                    the daemon.  Intended for a host that takes over
                    by manually flipping its role to "primary" (and
                    simultaneously demoting the previous primary)
                    during an outage.  The config + state dir are
                    ready so promotion needs no rebuild.
          none    — do nothing.  Host neither runs the daemon nor
                    serves the alias.

        Flip roles by editing host profile, updating the WAN port-
        forward target if the new primary lives on a different host,
        committing, and rolling out `darwin-rebuild switch` on both
        affected hosts.
      '';
    };
  };

  config = mkMerge [
    # Everything except the running daemons — CLI, config, state dir
    # setup — applies to both `primary` and `standby` so the latter is
    # promotion-ready with no further rebuild.
    (mkIf (cfg.role != "none") {
      # Install the CLI system-wide so the operator can run
      # `headscale users create`, `headscale preauthkeys create`, etc.
      # without fishing for the store path.  Available on both primary
      # and standby so a promoted standby can issue preauth keys
      # against the migrated DB immediately.
      environment.systemPackages = [
        headscalePkg
      ];

      # Register the port in /etc/services so `lsof -iTCP -sTCP:LISTEN`,
      # netstat, and similar tools render a descriptive name.  macOS
      # ships /etc/services as a real file (not nix-darwin managed), so
      # we append via activation rather than environment.etc.
      system.activationScripts.postActivation.text = lib.mkAfter ''
        if ! grep -qE '^${headscaleCatalog.serviceName}\s+${toString headscaleCatalog.listenPort}/tcp' /etc/services 2>/dev/null; then
          printf '%s\n' '${headscaleCatalog.serviceName} ${toString headscaleCatalog.listenPort}/tcp # Headscale bootstrap control-plane (modules/darwin/headscale-daemon.nix)' >> /etc/services
        fi
      '';
    })

    # Primary-only: the headscale daemon LaunchAgent.  Must run on
    # exactly one host at a time; the `role = "primary"` gate
    # enforces this per-host, and the operator is responsible for
    # not flipping two hosts to primary simultaneously.  Tailnet
    # clients reach the daemon via the public `aliasUrl` (DuckDNS →
    # Bbox WAN port-forward); see modules/darwin/headscale.nix.
    (mkIf (cfg.role == "primary") {
      launchd.user.agents.headscale-bootstrap = {
        command = "${headscaleLauncher}";
        serviceConfig = {
          Label = "io.nxmatic.nix-darwin-home.headscale-bootstrap";
          # Restart on crash.  Headscale is long-lived; transient
          # failures (port binding, DB lock) resolve themselves.
          KeepAlive = true;
          RunAtLoad = true;
          # Logs: launcher pipes stdout/stderr through `logger` into the
          # macOS unified log under the `headscale-bootstrap` tag — see
          # the launcher script.  Inspect with:
          #   log show --last 15m --predicate 'process == "logger"' | grep headscale-bootstrap
          #   log stream --predicate 'process == "logger"'
          ProcessType = "Background";
          LowPriorityIO = true;
        };
      };

      # The mDNS alias publisher (`headscale-mdns-publish`) was
      # retired earlier this fleet when alias resolution moved to
      # public DNS via DuckDNS + Bbox port-forward.  The Go publisher
      # at packages/ndh-mdns-publish/ is still consumed by the NixOS
      # peer module (via avahi-daemon) — left intact for a future
      # RKE2-hosted headscale scenario where a NixOS host might
      # serve a legacy alias.
    })
  ];
}
