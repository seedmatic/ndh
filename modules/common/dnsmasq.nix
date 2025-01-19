{
  config,
  lib,
  pkgs,
  ...
}: let
  user = config.profile.user;
  userName = user.name;
  logFile = "/Users/${userName}/Library/Logs/dnsmasq.log";
in {
  services.dnsmasq = {
    enable = true;
  };

  environment.etc."dnsmasq.conf".text = ''
    # Forward .internal queries to the custom DNS proxy
    server=/internal/127.0.0.1#5453

    # Optional: Use these for non-.internal domains
    server=8.8.8.8
    server=8.8.4.4

    # Listen on localhost
    listen-address=127.0.0.1
    port=53

    # Don't use /etc/resolv.conf
    no-resolv

    # Enable logging
    log-queries
    log-facility=${logFile}

    # Increase logging verbosity
    log-debug

    # Increase forwarding timeout (default is 5 seconds)
    dns-forward-max=150
    query-timeout=10
  '';

  launchd.daemons.dnsmasq = lib.mkForce {
    serviceConfig = {
      Label = "org.nixos.dnsmasq";
      ProgramArguments = [
        "${pkgs.dnsmasq}/bin/dnsmasq"
        "--conf-file=/etc/dnsmasq.conf"
        "--keep-in-foreground"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = logFile;
      StandardErrorPath = logFile;
    };
  };

  # Ensure the log file exists and is writable
  system.activationScripts.dnsmasqLogFile = lib.stringAfter ["users"] ''
    mkdir -p "$(dirname ${logFile})"
    touch "${logFile}"
    chmod 644 "${logFile}"
    chown ${userName}:staff "${logFile}"
  '';
}
