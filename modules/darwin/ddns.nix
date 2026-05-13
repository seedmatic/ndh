# Dynamic DNS client on Darwin — pushes the current WAN IPv4 to the
# provider hosting `catalog.netplan.wan.ddnsHostname` so clients
# reaching the fleet from off-LAN can resolve a stable name (the ISP
# gives us a dynamic public IP).
#
# Only bioskop runs this today; nikopol is a laptop that roams and
# has no authority over the home WAN IP.  The update interval is
# gentle (15 min) because residential IPs on Bouygues change rarely;
# operators can bump it per-host via `services.ddnsClient.interval`.
#
# The provider token is a sops secret.  If the secret is missing the
# LaunchAgent stays inert rather than shouting into the void.
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

  # Parse `bboxmatic.duckdns.org` into ("bboxmatic", "duckdns.org") so
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

  host = if wan != null then splitHost wan.ddnsHostname else { subDomain = ""; domainName = ""; };

  # sops secret key follows the .secrets schema:
  # `<provider>.<subdomain>.token` so a future second subdomain lives
  # alongside without colliding (e.g. `duckdns.office.token`).
  tokenSecretName = "duckdns.${host.subDomain}.token";
  tokenSecretPath = "/run/secrets/nix-darwin-home/${tokenSecretName}";

  # godns config is JSON; we materialise a wrapper at runtime that
  # substitutes the token from the sops-managed file into a generated
  # config.json under the state dir.  Keeping the token out of the
  # Nix store is the whole point of the sops pipeline.
  stateDir = "${config.users.users.${config.system.primaryUser}.home}/Library/Application Support/godns";

  # Static part of the config — provider, domains, intervals.  The
  # dynamic part (login_token) is injected by the launcher from the
  # sops secret at activation / service-start time.
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
    ip_type = "IPv4";
    interval = cfg.interval;
    resolver = "1.1.1.1";
    user_agent = "godns/nix-darwin-home";
  };

  configTemplate = pkgs.writeText "godns-config-template.json" configStaticJson;

  launcher = pkgs.writeShellScript "godns-launcher" ''
    set -euo pipefail

    STATE_DIR=${lib.escapeShellArg stateDir}
    TOKEN_FILE=${lib.escapeShellArg tokenSecretPath}
    CONFIG_FILE="$STATE_DIR/config.json"
    CONFIG_TMPL=${configTemplate}

    if [ ! -r "$TOKEN_FILE" ]; then
      echo "[godns] token secret not readable at $TOKEN_FILE — staying inactive" >&2
      # Exit 0 so KeepAlive doesn't loop on a config bootstrap condition
      # that only flips once after the operator places the sops secret.
      exit 0
    fi

    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR"

    # Substitute the token into a per-activation config file.  Written
    # with restrictive permissions since it now contains the secret in
    # plaintext; sits under ~/Library/Application Support so it is not
    # world-readable even if the mode slipped.
    token="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    ${pkgs.gnused}/bin/sed -e "s|@TOKEN@|$token|g" "$CONFIG_TMPL" > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"

    exec ${lib.getExe pkgs.godns} -c "$CONFIG_FILE"
  '';
in
{
  options.services.ddnsClient = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run godns on this Darwin host to keep
        `catalog.netplan.wan.ddnsHostname` aligned with the current
        WAN IPv4.  Only the host authoritative for the home WAN
        anchor should enable this (bioskop today).
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
        message = "services.ddnsClient could not split catalog.netplan.wan.ddnsHostname = \"${toString (wan.ddnsHostname or "<unset>")}\" into subDomain + domainName.";
      }
    ];

    environment.systemPackages = [ pkgs.godns ];

    sops.secrets.${tokenSecretName} = {
      format = "yaml";
      sopsFile = cfg.sopsEncryptedTokenFile;
      # Key path follows the .secrets YAML tree:
      #   duckdns:
      #     <subDomain>:
      #       token: ENC[...]
      key = "duckdns/${host.subDomain}/token";
      path = tokenSecretPath;
      # godns runs under the LaunchAgent's user context (gui/<uid>), not
      # root, so sops-nix's default owner=root / mode=0400 would make
      # the token unreadable from the agent.  Hand the file to the
      # profile user so the launcher can cat it at service start.
      owner = config.system.primaryUser;
      mode = "0400";
    };

    launchd.user.agents.ddns-client = {
      command = "${launcher}";
      serviceConfig = {
        Label = "io.nxmatic.nix-darwin-home.ddns-client";
        # godns is long-lived with its own interval; launchd wraps it
        # with KeepAlive so a transient network failure restart is
        # cheap.
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${config.users.users.${config.system.primaryUser}.home}/Library/Logs/ddns-client.log";
        StandardErrorPath = "${config.users.users.${config.system.primaryUser}.home}/Library/Logs/ddns-client.err.log";
        ProcessType = "Background";
        LowPriorityIO = true;
      };
    };
  };
}
