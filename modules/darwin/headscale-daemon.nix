# Headscale bootstrap daemon — runs as a user LaunchAgent on each
# operator Darwin host.  Owns the tailnet control-plane during the
# bootstrap phase, before the rke2-hosted production instance exists.
#
# State lives under `~/Library/Application Support/Headscale/`, matching
# macOS conventions for user daemons (Time Machine-backed up,
# sandbox-friendly).  The binary comes from pkgs.headscale.
#
# Policy is pinned to the Nix-store copy of
# `catalog.headscale.aclPolicyFile`; reloading the daemon re-reads it,
# so editing the ACL + running `darwin-rebuild switch` is the full
# apply cycle — no separate `headscale policy set` post-activation
# hook needed.
#
# Clients authenticate via pre-auth keys.  Keys are created on first
# use with `headscale preauthkeys create --user <user>`; they are NOT
# provisioned by this module (one-time bootstrap concern).  Once a
# client registers, re-registrations use the stored node key.
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
  headscaleCatalog = catalog.headscale;
  hostName = config.networking.hostName or "localhost";

  # Pull headscale from nixpkgs-unstable so we land on the 0.28.x line,
  # which brings the pre-auth-key format changes announced in the 0.28
  # release notes (breaking vs. 0.27).  Pinned to the `>= 0.28, < 0.29`
  # band so that an unstable bump to 0.29 (expected to carry another
  # round of breaking changes) can't silently land via a flake lock
  # update — the module falls back to pkgs.headscale instead, which
  # flags the regression via the 0.27 runtime complaining about 0.28
  # DB columns.  Same pattern as [bringup-observe.nix] for Vector.
  headscalePkg =
    let
      unstable = import self.inputs.nixpkgs-unstable {
        system = pkgs.stdenv.hostPlatform.system;
        config = pkgs.config;
      };
      v = unstable.headscale.version or "0.0.0";
      withinBand = lib.versionAtLeast v "0.28.0" && !lib.versionAtLeast v "0.29.0";
    in
    if withinBand
    then unstable.headscale
    else pkgs.headscale;

  # Clients always resolve `aliasName` via mDNS to the host currently
  # holding role = "primary"; the daemon itself is told to issue
  # certificates and registration URLs under that same alias, so a
  # standby→primary flip on a different host is transparent at the
  # tailnet level (same server_url, new backing IP).
  serverUrl = headscaleCatalog.aliasUrl;

  # XDG split: config at `~/.config/headscale/` (rendered per-activation
  # from the Nix store) vs persistent data at `~/.local/share/headscale/`
  # (SQLite DB, node/noise keys, unix socket — survives across
  # rebuilds, included in the operator's backup sweep).  Matches the
  # convention already used by godns ([ddns.nix]) and sidesteps the
  # macOS-native `~/Library/Application Support/Headscale/` path whose
  # embedded space trips tools that split their arguments on
  # whitespace.
  homeDir = config.users.users.${config.system.primaryUser}.home;
  configDir = "${homeDir}/.config/headscale";
  dataDir = "${homeDir}/.local/share/headscale";
  configFile = "${configDir}/config.yaml";

  # On Darwin we publish the alias through Apple's own mDNSResponder via
  # `dns-sd -P` (proxy registration) rather than standing up a parallel
  # responder.  Any third-party binary that binds UDP 5353 loses to
  # mDNSResponder for `.local` lookups — queries from local clients go
  # through the system stub resolver straight to mDNSResponder, which
  # answers authoritatively for registered names only.  `dns-sd -P`
  # registers the alias with mDNSResponder itself, so it shows up in
  # `dscacheutil`, `ping foo.local`, and every framework that honours
  # the system resolver.  The Go publisher at
  # packages/ndh-mdns-publish/ is still used by the NixOS peer module
  # (avahi-daemon there has the same ownership but different registration
  # APIs).
  dnsSdPublisher = pkgs.writeShellScript "headscale-dns-sd-publisher" ''
    set -euo pipefail
    exec > >(/usr/bin/logger -t headscale-mdns-publish) 2>&1

    # Pick the first non-loopback IPv4 on the default route interface so
    # the proxy record points at whatever address clients on the LAN can
    # actually reach.  `/sbin/route -n get default` (macOS native) prints
    # the interface name; `/usr/sbin/ipconfig getifaddr` reads its
    # primary IPv4.  Both live in the base system, so no PATH dependency
    # on the Nix store.
    iface="$(/sbin/route -n get default 2>/dev/null | ${pkgs.gnugrep}/bin/grep 'interface:' | ${pkgs.gawk}/bin/awk '{print $2}')"
    if [ -z "$iface" ]; then
      echo "[headscale-mdns] no default route interface — cannot publish alias" >&2
      exit 1
    fi
    ip="$(/usr/sbin/ipconfig getifaddr "$iface" || true)"
    if [ -z "$ip" ]; then
      echo "[headscale-mdns] no IPv4 on $iface — cannot publish alias" >&2
      exit 1
    fi

    # dns-sd -P <Name> <Type> <Domain> <Port> <Host> <IP>
    # <Host> is the literal A-record target that the registered SRV
    # will point at — NOT concatenated with <Domain>.  So it must be
    # the full alias including the `.local` suffix; passing just
    # `headscale.mammoth-skate` makes the SRV target unresolvable
    # because there is no matching A record.  Stays in foreground;
    # launchd tracks the process and reaps it on unload —
    # mDNSResponder then withdraws the registration automatically.
    exec /usr/bin/dns-sd -P \
      ${lib.escapeShellArg headscaleCatalog.serviceName} \
      _${headscaleCatalog.serviceName}._tcp \
      local \
      ${toString headscaleCatalog.listenPort} \
      ${lib.escapeShellArg headscaleCatalog.aliasName} \
      "$ip"
  '';

  # Headscale config.yaml.  Values substituted in from the catalog.
  # Everything pinned to the state dir so re-activation doesn't relocate
  # running state.  `policy.path` resolves to the Nix store — the file
  # is a symlink target into the flake closure, immutable per generation.
  headscaleConfigYaml = pkgs.writeText "headscale-config.yaml" ''
    # Generated by modules/darwin/headscale-daemon.nix — do not edit by
    # hand.  Config itself is re-rendered on every darwin-rebuild
    # switch and symlinked from ${configDir}; persistent state (DB,
    # keys, socket) lives in ${dataDir}.

    server_url: ${serverUrl}
    listen_addr: 0.0.0.0:${toString headscaleCatalog.listenPort}

    # Metrics listener on localhost only — exposing is optional.
    metrics_listen_addr: 127.0.0.1:${toString (headscaleCatalog.listenPort + 1)}

    # Tailnet address pools headscale hands out to joining nodes.  v4
    # mirrors catalog.netplan.tailnet.cidr (100.64.0.0/10 = the CGNAT
    # space Tailscale has always used); v6 is headscale's own default
    # ULA range.  At least one prefix is required since headscale
    # 0.26+.
    prefixes:
      v4: ${catalog.netplan.tailnet.cidr}
      v6: fd7a:115c:a1e0::/48
      allocation: sequential

    # State material headscale creates lazily if missing.
    private_key_path: ${dataDir}/private.key
    noise:
      private_key_path: ${dataDir}/noise_private.key

    # SQLite is fine for a single-operator bootstrap instance.
    database:
      type: sqlite3
      sqlite:
        path: ${dataDir}/db.sqlite

    # ACL policy sourced from the flake catalog.  Store-path means
    # reloading reads whatever the current generation pins; to change
    # the policy, edit catalog/headscale/acl.hujson + darwin-rebuild
    # switch.
    policy:
      mode: file
      path: ${headscaleCatalog.aclPolicyFile}

    # DNS is kept minimal: no MagicDNS override, no extra records.
    # Clients already get their own mDNS resolution; MagicDNS adds a
    # layer we don't need for the 2-operator fleet.
    dns:
      magic_dns: true
      base_domain: mammoth-skate.ts.net
      nameservers:
        global:
          - 1.1.1.1
          - 8.8.8.8

    # Logging: journal-style, info level, stderr so launchd captures
    # into ~/Library/Logs.
    log:
      level: info
      format: text

    # DERP (relays): use the public Tailscale DERP map.  Good enough
    # for LAN + cross-LAN; a self-hosted DERP is a future follow-up.
    derp:
      server:
        enabled: false
      urls:
        - https://controlplane.tailscale.com/derpmap/default
      auto_update_enabled: true
      update_frequency: 24h

    # Disable features we don't use.
    ephemeral_node_inactivity_timeout: 30m
    unix_socket: ${dataDir}/headscale.sock
    unix_socket_permission: "0770"
  '';

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
      type = types.enum [ "primary" "standby" "none" ];
      default = "none";
      description = ''
        This host's role in the headscale bootstrap topology.

          primary — run the daemon AND publish the fleet-scoped mDNS
                    alias (catalog.headscale.aliasName) so clients
                    resolve aliasUrl to this host.  Exactly one host
                    should be primary at a time.
          standby — install the headscale CLI + config but do NOT run
                    the daemon and do NOT publish the alias.  Intended
                    for a host that takes over by manually flipping
                    its role to "primary" (and simultaneously
                    demoting the previous primary) during an outage.
                    The config + state dir are ready so promotion
                    needs no rebuild.
          none    — do nothing.  Host neither runs the daemon nor
                    advertises the alias.

        Flip roles by editing host profile, committing, and rolling
        out `darwin-rebuild switch` on both affected hosts.  Clients
        pointed at aliasUrl continue without re-registration because
        the mDNS alias follows ownership transparently.
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

    # Primary-only: the two LaunchAgents that together own the alias
    # identity (daemon + mdns publisher).  Both must run on exactly
    # one host at a time; the `role = "primary"` gate enforces this
    # per-host, and the operator is responsible for not flipping two
    # hosts to primary simultaneously.
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

      # mDNS alias: registers `<aliasName> A <this-host-IP>` with Apple's
      # mDNSResponder via `dns-sd -P` for the lifetime of the agent.
      # When launchd stops the process, mDNSResponder withdraws the
      # registration and sends a goodbye packet automatically; KeepAlive
      # restarts on crash but the window of unresolvability is brief.
      launchd.user.agents.headscale-mdns-publish = {
        command = "${dnsSdPublisher}";
        serviceConfig = {
          Label = "io.nxmatic.nix-darwin-home.headscale-mdns-publish";
          KeepAlive = true;
          RunAtLoad = true;
          # Logs: launcher pipes stdout/stderr through `logger` into the
          # macOS unified log under the `headscale-mdns-publish` tag.
          ProcessType = "Background";
          LowPriorityIO = true;
        };
      };
    })
  ];
}
