{ config, pkgs, ... }:
{
  imports = [
    ../../modules/nixos/mcp-browser-forward.nix
    ../../modules/nixos/host-nixos-base.nix
  ];

  config = {
    ndh.hostNixosBase.enable = true;

    # Cache signing (private deploy + trusted-public-keys + /etc/nix/*.pub)
    # is wired fleet-wide in modules/.common.d/nix-signing.nix — nothing
    # host-specific here.

    # BrowserOS's MCP server answers loopback peers only, so each Mac's :9010 is reached through an ssh opened on
    # demand, by the split-DNS name `darwin.<host>`: nikopol on :9010 here, bioskop on :9020.
    ndh.mcpBrowserForward = {
      enable = true;
      host = "bioskop";
    };
    ndh.onDemandTunnel = {
      # browseros-bioskop is now provided by the system service
      # io-seedmatic-ndh-mcp-browser-forward (no user session required).
      browseros-nikopol = {
        host = "nikopol";
        port = 9010;
        listenPort = 9020;
      };
    };

    # omo (AI coding assistant) on NixOS
    home-manager.users.${config.profile.user.name}.imports = [
      ./modules/home-manager/omo.nix
    ];
  };
}
