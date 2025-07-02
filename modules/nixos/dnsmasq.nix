{ config, lib, pkgs, ... }: {
  services.dnsmasq = {
    enable = true;
  };

  # Optionally, add a systemd override if you need custom logging or startup
  # systemd.services.dnsmasq = { ... };
}