# Optional additional D-Bus system bus TCP listener for private lab networking (@codebase)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.dbusTcpSystemBus;
  dbusCfg = config.services.dbus;
  dbusTcpAssetsDir = ./dbus-tcp.d;
  tcpListenStream = "${cfg.bindAddress}:${toString cfg.port}";
  baseDbusConfigDir = pkgs.makeDBusConf.override {
    inherit (dbusCfg) apparmor;
    dbus = dbusCfg.dbusPackage;
    suidHelper = "${config.security.wrapperDir}/dbus-daemon-launch-helper";
    serviceDirectories = dbusCfg.packages;
  };

  insecureDbusConfigDir = pkgs.runCommand "dbus-1-insecure-config"
    {
      preferLocalBuild = true;
      allowSubstitutes = false;
    }
    ''
      cp -r --no-preserve=mode,ownership ${baseDbusConfigDir} "$out"
      chmod -R u+w "$out"

      ${pkgs.patch}/bin/patch \
        --batch \
        --forward \
        --fuzz=3 \
        --no-backup-if-mismatch \
        "$out/system.conf" \
        ${dbusTcpAssetsDir + "/system-conf-auth-anonymous.patch"}

      ${pkgs.perl}/bin/perl -0777 -i -pe 's#</busconfig>#  <policy context="default">\n    <allow send_destination="*"/>\n    <allow eavesdrop="true"/>\n    <allow own="*"/>\n    <allow receive_sender="*"/>\n  </policy>\n</busconfig>#s' "$out/system.conf"

      chmod -R a-w "$out"
    '';
in
{
  options.services.dbusTcpSystemBus = {
    enable = lib.mkEnableOption "D-Bus system bus TCP listener";

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "IPv4 bind address for the additional D-Bus TCP listener.";
      example = "10.80.0.1";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 12434;
      description = "TCP port for the additional D-Bus system bus listener.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the configured D-Bus TCP port in the NixOS firewall.";
    };

    insecureAllowAnonymous = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        LAB-ONLY. When enabled, allows anonymous auth and permissive bus policy on
        the system bus (affects both Unix socket and TCP listener).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # dbus-daemon is started with --address=systemd, so listeners must be
    # provided by systemd sockets (not dbus XML <listen> snippets).
    # Declare both listeners explicitly so the generated drop-in always keeps
    # the local Unix system bus socket and the lab TCP listener.
    systemd.sockets.dbus.socketConfig.ListenStream = [
      "/run/dbus/system_bus_socket"
      tcpListenStream
    ];

    # Allow binding the TCP listener before the vmnet address is configured.
    # This avoids early-boot dbus.socket failures such as:
    #   Cannot assign requested address
    # when the configured bindAddress appears later in boot.
    systemd.sockets.dbus.socketConfig.FreeBind = true;

    # IMPORTANT: this NixOS channel does not expose services.dbus.extraConfig.
    # For lab-only anonymous auth we override the generated dbus-1 config dir
    # with a patched system.conf that adds ANONYMOUS auth + permissive policy.
    environment.etc."dbus-1".source = lib.mkIf cfg.insecureAllowAnonymous (lib.mkForce insecureDbusConfigDir);

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
