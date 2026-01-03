{ config, lib, ... }:

{
  # Enable mDNS/Avahi so .local names resolve inside the VM.
  services.avahi = {
    enable = true;
    nssmdns = true;
    openFirewall = true;
  };

  # Ensure systemd-resolved handles mDNS/LLMNR; keep DNSSEC permissive for LAN.
  services.resolved = {
    enable = lib.mkDefault true;
    dnssec = lib.mkDefault "false";
    domains = lib.mkDefault [ "lan" "local" ];
    extraConfig = lib.mkDefault ''
      MulticastDNS=yes
      LLMNR=yes
    '';
  };
}
