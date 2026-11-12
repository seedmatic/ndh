{ config, lib, pkgs, ndh, ... }:
let
  cfg = config.ndh.mcpBrowserForward;
  tailnetDomain = ndh.context.catalog.netplan.tailnet.domain;
in
{
  imports = [ ./systemd/naming.nix ];

  options.ndh.mcpBrowserForward = {
    enable = lib.mkEnableOption "system-level forward of the Darwin BrowserOS MCP server on :9010";
    host = lib.mkOption {
      type = lib.types.str;
      default = "nikopol";
      description = "Fleet host (nikopol/bioskop) whose Darwin MCP server is forwarded.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.${config._module.args.config._module.args.ndhSystemd.mkNdhServiceName "mcp-browser-forward"} = {
      description = "Forward TCP/9010 to Darwin MCP browser server (${cfg.host})";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        User = config.profile.user.name;
        Group = config.profile.user.name;
        Environment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/bin:/usr/bin";
        ExecStart = lib.escapeShellArgs [
          "${pkgs.openssh}/bin/ssh"
          "-N"
          "-o" "BatchMode=yes"
          "-o" "ControlMaster=no"
          "-o" "ControlPath=none"
          "-o" "ServerAliveInterval=15"
          "-o" "ServerAliveCountMax=3"
          "-o" "ExitOnForwardFailure=yes"
          "-o" "StrictHostKeyChecking=yes"
          "-o" "HostName=darwin.${cfg.host}"
          "-o" "HostKeyAlias=${cfg.host}${tailnetDomain}"
          "-L" "127.0.0.1:9010:localhost:9010"
          "darwin.${cfg.host}"
        ];
        Restart = "always";
        RestartSec = "5";
      };
    };
  };
}
