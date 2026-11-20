{
  config,
  pkgs,
  lib,
  ndh,
  ...
}:
let
  bm = ndh.context.catalog.netplan.baremetal.nikopol;
in
{
  imports = [
    ../../modules/nixos/mcp-browser-forward.nix
    ../../modules/nixos/host-nixos-base.nix
  ];

  config = {
    ndh.hostNixosBase = {
      enable = true;
      enableStoreFreeze = true;
    };

    # Fabric link for the darwin.nikopol VM: a /30 on the home-LAN L2 so the VM
    # gets its OWN fabric address (172.16.25.2), distinct from vzhost.nikopol
    # (172.16.24.2).  This host owns the .1 end on lan-br; the VM aliases .2 on
    # its en0 and routes fabric/tailnet via .1 (see hosts/nikopol/darwin.nix).
    systemd.network.networks."40-lan-br".address = lib.mkAfter [ "172.16.25.1/30" ];

    # The vz host serves its LLM gateway agent on its loopback :4001 only; this guest publishes it on the fabric
    # gateway address for the two operator seats, which both arrive over the tailnet (measured 2026-10-21).
    ndh.loopbackForward.vzhost-4001 = {
      listen = {
        address = bm.netGateway;
        port = 4001;
      };
      target = {
        address = bm.vzHostAddress;
        user = bm.vzHostUser;
        hostKey = bm.vzHostKey;
        port = 4001;
      };
      from = bm.hostAddress;
      clients = [
        "100.76.71.8" # darwin.bioskop
        "100.89.203.77" # darwin.nikopol
        bm.netGateway # nixos.nikopol itself: local consumers (omo on the guest)
      ];
    };

    # BrowserOS's MCP server answers loopback peers only, so each Mac's :9010 is reached through an ssh opened on
    # demand, by the split-DNS name `darwin.<host>`: nikopol on :9010 here, bioskop on :9020.
    ndh.mcpBrowserForward = {
      enable = true;
      host = "nikopol";
    };
    ndh.onDemandTunnel = {
      # browseros-nikopol is now provided by the system service
      # io-seedmatic-ndh-mcp-browser-forward (no user session required).
      browseros-bioskop = {
        host = "bioskop";
        port = 9010;
        listenPort = 9020;
      };
    };

    # omo (AI coding assistant) on NixOS
    home-manager.users.${config.profile.user.name}.imports = [
      ./modules/home-manager/omo.nix
      ./modules/home-manager/ssh-lan-override.nix
    ];
  };
}
