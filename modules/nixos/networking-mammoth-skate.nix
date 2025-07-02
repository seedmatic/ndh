{ config, lib, ... }: {
  options.networking.mammoth-skate = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description =
        "Enable networking configuration for the mammoth-skate tailnet.";
    };
  };

  config = lib.mkIf config.networking.mammoth-skate.enable {
    networking = {
      firewall.enable = true;
      firewall.allowedTCPPorts = [ 22 2222 ];
      nftables.enable = true;
      networkmanager.enable = true;
      wireless.enable = false;
      nameservers =
        [ "100.100.100.100" "1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.4.4" ];
      fqdn = config.networking.hostName + ".mammoth-skate.ts.net";
      search = [ "mammoth-skate.ts.net" ];
    };
    systemd.network.networks.eth0.networkConfig = {
      DHCP = "yes";
      LinkLocalAddressing = "yes";
    };
  };
}
