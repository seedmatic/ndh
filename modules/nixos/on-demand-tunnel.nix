# Publishes a port that a Darwin host serves on its loopback only, on this guest's loopback, opening the ssh tunnel
# when something connects and not before.
#
# Made for BrowserOS's MCP server (:9010), which answers loopback peers only: a connection from the LAN is accepted
# and closed with no HTTP response, whatever its Host header. systemd owns the listening socket (Accept=yes), and
# each accepted connection runs one `ssh -W` as the operator, over the operator's own ssh config, so there is no
# resident ssh, no reconnect loop and no key of its own.
#
# The target is dialled by its split-DNS name (`darwin.<host>`), never by an address. That zone name is not the
# one the host key is vouched for: the fleet authority covers the tailnet names, so the host key is checked under
# the tailnet name, read from the catalog (HostKeyAlias), with strict checking left on.
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  inherit (lib) mkOption types;
  tunnels = config.ndh.onDemandTunnel;
  tailnetDomain = ndh.context.catalog.netplan.tailnet.domain;
  user = config.profile.user.name;
  unitName = name: "ndh-tunnel-${name}";
in
{
  options.ndh.onDemandTunnel = mkOption {
    default = { };
    description = "Loopback ports of a Darwin host, reachable here on demand through ssh.";
    type = types.attrsOf (
      types.submodule {
        options = {
          host = mkOption {
            type = types.str;
            description = "The fleet host, as in `darwin.<host>`: its split-DNS name is dialled, and its tailnet name vouches for the host key.";
          };
          service = mkOption {
            type = types.str;
            default = "darwin";
            description = "The ssh alias prefix of the machine serving the port (`<service>.<host>`).";
          };
          port = mkOption {
            type = types.port;
            description = "The port the target serves on its loopback.";
          };
          listenPort = mkOption {
            type = types.port;
            description = "The port listened on here, on 127.0.0.1: one per target, since every Darwin host serves the same port.";
          };
        };
      }
    );
  };

  config = lib.mkIf (tunnels != { }) {
    systemd.user.sockets = lib.mapAttrs' (
      name: t:
      lib.nameValuePair (unitName name) {
        description = "On-demand tunnel :${toString t.listenPort} to ${t.service}.${t.host} :${toString t.port}";
        wantedBy = [ "sockets.target" ];
        # A user manager exists per account; only the operator's may own the port.
        unitConfig.ConditionUser = user;
        listenStreams = [ "127.0.0.1:${toString t.listenPort}" ];
        socketConfig.Accept = true;
      }
    ) tunnels;

    systemd.user.services = lib.mapAttrs' (
      name: t:
      lib.nameValuePair "${unitName name}@" {
        description = "Tunnel to ${t.service}.${t.host} :${toString t.port} for one connection";
        serviceConfig = {
          ExecStart = lib.escapeShellArgs [
            "${pkgs.openssh}/bin/ssh"
            "-T"
            "-o"
            "BatchMode=yes"
            # The operator's masters outlive the connection and idle for minutes: this one exits with its peer.
            "-o"
            "ControlMaster=no"
            "-o"
            "ControlPath=none"
            "-o"
            "ServerAliveInterval=15"
            "-o"
            "HostName=${t.service}.${t.host}"
            "-o"
            "HostKeyAlias=${t.host}${tailnetDomain}"
            "${t.service}.${t.host}"
            "-W"
            "127.0.0.1:${toString t.port}"
          ];
          StandardInput = "socket";
          StandardOutput = "socket";
          StandardError = "journal";
        };
      }
    ) tunnels;
  };
}
