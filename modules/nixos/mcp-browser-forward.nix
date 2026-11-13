{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  cfg = config.ndh.mcpBrowserForward;
  tailnetDomain = ndh.context.catalog.netplan.tailnet.domain;
  ndhPrefix = import ./systemd/ndh-prefix.nix { inherit lib; };
  unitName = ndhPrefix.mkNdhUnitName "mcp-browser-forward";
  user = config.profile.user.name;
in
{
  options.ndh.mcpBrowserForward = {
    enable = lib.mkEnableOption "system-level on-demand forward of the Darwin BrowserOS MCP server on :9010";
    host = lib.mkOption {
      type = lib.types.str;
      default = "nikopol";
      description = "Fleet host (nikopol/bioskop) whose Darwin MCP server is forwarded.";
    };
  };

  # BrowserOS's MCP server answers loopback peers only, so it is reached through ssh. systemd owns 127.0.0.1:9010
  # (Accept=yes) and runs one `ssh -W` per accepted connection, as the operator and over the operator's ssh config:
  # nothing resident, nothing reconnecting, and no user session needed (system units, unlike
  # on-demand-tunnel.nix's user ones).
  config = lib.mkIf cfg.enable {
    systemd.sockets.${unitName} = {
      description = "On-demand forward of 127.0.0.1:9010 to Darwin MCP browser server (${cfg.host})";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "127.0.0.1:9010" ];
      socketConfig.Accept = true;
    };

    systemd.services."${unitName}@" = {
      description = "Forward one connection to Darwin MCP browser server (${cfg.host})";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        User = user;
        Group = user;
        Environment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/bin:/usr/bin";
        ExecStart = lib.escapeShellArgs [
          "${pkgs.openssh}/bin/ssh"
          "-T"
          "-o"
          "BatchMode=yes"
          # The operator's masters outlive the connection: this ssh exits with its peer.
          "-o"
          "ControlMaster=no"
          "-o"
          "ControlPath=none"
          "-o"
          "ServerAliveInterval=15"
          "-o"
          "ServerAliveCountMax=3"
          "-o"
          "StrictHostKeyChecking=yes"
          "-o"
          "HostName=darwin.${cfg.host}"
          "-o"
          "HostKeyAlias=${cfg.host}${tailnetDomain}"
          "darwin.${cfg.host}"
          "-W"
          "127.0.0.1:9010"
        ];
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
      };
    };
  };
}
