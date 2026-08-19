# Dynamic DNS client on Darwin — pushes the current WAN IPv4 + IPv6
# to the provider hosting `catalog.netplan.wan.ddnsHostname` so
# clients reaching the fleet from off-LAN can resolve a stable name
# (the ISP gives us a dynamic public IP).
#
# Two LaunchAgents run in parallel — one per stack — because godns's
# `ip_type` accepts only `IPV4` or `IPV6`; there is no `dual` mode in
# a single instance (see internal/utils/constants.go + pkg/lib/ip_helper.go
# in the upstream source).  Each agent pushes its own record under the
# same Duck DNS FQDN; Duck DNS's idempotent update endpoint keeps the
# A and AAAA records independent.
#
# Only bioskop runs this today; nikopol is a laptop that roams and
# has no authority over the home WAN IP.  The update interval is
# gentle (15 min) because residential IPs on Bouygues change rarely;
# operators can bump it per-host via `services.ddnsClient.interval`.
#
# The provider token is a sops secret shared across both agents.  If
# the secret is missing the LaunchAgents stay inert rather than
# shouting into the void.
{
  config,
  pkgs,
  lib,
  ndh,
  ...
}:

with lib;

let
  cfg = config.services.ddnsClient;
  ndhContext = ndh.context;
  catalog = ndhContext.catalog;
  wan = catalog.netplan.wan or null;

  # Parse `mammoth-skate.duckdns.org` into ("mammoth-skate", "duckdns.org") so
  # godns's config schema — which splits on the registered domain —
  # gets the right halves.  Assumes a single-label subdomain + a
  # known two-label apex; good enough for Duck DNS.
  splitHost =
    fqdn:
    let
      parts = lib.splitString "." fqdn;
    in
    {
      subDomain = builtins.head parts;
      domainName = lib.concatStringsSep "." (builtins.tail parts);
    };

  host =
    if wan != null then
      splitHost wan.ddnsHostname
    else
      {
        subDomain = "";
        domainName = "";
      };

  # Duck DNS tokens are account-scoped, not per-subdomain: one token
  # authorises updates for every subdomain under a DuckDNS account.
  # `.secrets` mirrors that with a flat `duckdns.token` entry; if we
  # ever add a second provider (Cloudflare, Hetzner, …) it would sit
  # at the same level as a sibling `<provider>.token`.
  tokenSecretName = "duckdns.token";
  tokenSecretPath = "/run/secrets/nix-darwin-home/${tokenSecretName}";

  # XDG config directory (`~/.config/godns/`) rather than the
  # macOS-native `~/Library/Application Support/godns/`: godns's
  # config loader splits on whitespace before picking the file
  # extension, and the space in `Application Support` trips it into
  # rejecting the .json file as "invalid file extension".
  stateDirBase = "${config.users.users.${config.system.primaryUser}.home}/.config/godns";

  # Per-stack agent factory.  Each invocation produces the pieces
  # needed to register one LaunchAgent: a config template, a launcher
  # script, and the launchd attrset.  Stacks differ only by `ipType`
  # (`IPV4` vs `IPV6`) and web-panel bind port so the two instances
  # don't collide on 9000.
  mkDdnsAgent =
    { ipType, webPanelPort }:
    let
      stackTag = lib.toLower ipType;
      stateDir = "${stateDirBase}/${stackTag}";

      configStaticJson = builtins.toJSON {
        provider = "DuckDNS";
        login_token = "@TOKEN@";
        domains = [
          {
            domain_name = host.domainName;
            sub_domains = [ host.subDomain ];
          }
        ];
        ip_urls = [
          "https://api4.ipify.org"
          "https://ipecho.net/plain"
          "https://ifconfig.me/ip"
        ];
        ipv6_urls = [
          "https://api6.ipify.org"
          "https://api-ipv6.ip.sb/ip"
          "https://v6.ipinfo.io/ip"
        ];
        ip_type = ipType;
        interval = cfg.interval;
        resolver = "1.1.1.1";
        user_agent = "godns/nix-darwin-home-${stackTag}";
        # Web panel bound to loopback only — reachable via
        # `ssh -L <port>:127.0.0.1:<port> bioskop.local` then
        # http://localhost:<port> or directly from bioskop itself.
        # Credentials are `admin:admin` because the panel is not
        # exposed beyond loopback; harden with a sops-backed password
        # if it ever binds a routable interface.
        web_panel = {
          enabled = true;
          addr = "127.0.0.1:${toString webPanelPort}";
          username = "admin";
          password = "admin";
        };
      };

      configTemplate = pkgs.writeText "godns-config-template-${stackTag}.json" configStaticJson;

      launcher = pkgs.writeShellScript "godns-launcher-${stackTag}" ''
        set -euo pipefail

        STATE_DIR=${lib.escapeShellArg stateDir}
        TOKEN_FILE=${lib.escapeShellArg tokenSecretPath}
        CONFIG_FILE="$STATE_DIR/config.json"
        CONFIG_TMPL=${configTemplate}

        if [ ! -r "$TOKEN_FILE" ]; then
          echo "[godns-${stackTag}] token secret not readable at $TOKEN_FILE — staying inactive" >&2
          # Exit 0 so KeepAlive doesn't loop on a config bootstrap condition
          # that only flips once after the operator places the sops secret.
          exit 0
        fi

        mkdir -p "$STATE_DIR"
        chmod 0700 "$STATE_DIR"

        # Substitute the token into a per-activation config file.  Written
        # with restrictive permissions since it now contains the secret in
        # plaintext; sits under the user's private state dir.
        token="$(tr -d '[:space:]' < "$TOKEN_FILE")"
        ${pkgs.gnused}/bin/sed -e "s|@TOKEN@|$token|g" "$CONFIG_TMPL" > "$CONFIG_FILE"
        chmod 0600 "$CONFIG_FILE"

        exec ${lib.getExe pkgs.godns} -c "$CONFIG_FILE"
      '';

      agentName = "ddns-client-${stackTag}";
    in
    {
      inherit agentName;
      agent = {
        command = "${launcher}";
        serviceConfig = {
          Label = "io.seedmatic.ndh.${agentName}";
          # godns is long-lived with its own interval; launchd wraps it
          # with KeepAlive so a transient network failure restart is
          # cheap.
          KeepAlive = true;
          RunAtLoad = true;
          StandardOutPath = "${
            config.users.users.${config.system.primaryUser}.home
          }/Library/Logs/${agentName}.log";
          StandardErrorPath = "${
            config.users.users.${config.system.primaryUser}.home
          }/Library/Logs/${agentName}.err.log";
          ProcessType = "Background";
          LowPriorityIO = true;
        };
      };
    };

  ipv4Agent = mkDdnsAgent {
    ipType = "IPV4";
    webPanelPort = 9000;
  };
  ipv6Agent = mkDdnsAgent {
    ipType = "IPV6";
    webPanelPort = 9001;
  };
in
{
  options.services.ddnsClient = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run godns on this Darwin host to keep
        `catalog.netplan.wan.ddnsHostname` aligned with the current
        WAN IPv4 + IPv6.  Only the host authoritative for the home
        WAN anchor should enable this (bioskop today).
      '';
    };

    interval = mkOption {
      type = types.ints.positive;
      default = 900;
      description = ''
        Update interval in seconds.  Default 900 (15 minutes) because
        Bouygues residential IPs change rarely; smaller values make
        failover after an IP change faster.  Duck DNS's free tier
        handles 1-minute updates without complaining.
      '';
    };

    sopsEncryptedTokenFile = mkOption {
      type = types.path;
      description = ''
        Path to the sops-encrypted YAML carrying `ddns/duckdns/token`.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = wan != null;
        message = "services.ddnsClient.enable requires catalog.netplan.wan to be populated.";
      }
      {
        assertion = host.subDomain != "" && host.domainName != "";
        message = "services.ddnsClient could not split catalog.netplan.wan.ddnsHostname = \"${
          toString (wan.ddnsHostname or "<unset>")
        }\" into subDomain + domainName.";
      }
    ];

    environment.systemPackages = [ pkgs.godns ];

    sops.secrets.${tokenSecretName} = {
      format = "yaml";
      sopsFile = cfg.sopsEncryptedTokenFile;
      # Key path follows the .secrets YAML tree:
      #   duckdns:
      #     token: ENC[...]
      key = "duckdns/token";
      path = tokenSecretPath;
      # godns runs under the LaunchAgent's user context (gui/<uid>), not
      # root, so sops-nix's default owner=root / mode=0400 would make
      # the token unreadable from the agent.  Hand the file to the
      # profile user so the launcher can cat it at service start.
      owner = config.system.primaryUser;
      mode = "0400";
    };

    launchd.user.agents.${ipv4Agent.agentName} = ipv4Agent.agent;
    launchd.user.agents.${ipv6Agent.agentName} = ipv6Agent.agent;
  };
}
