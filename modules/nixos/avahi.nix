{ config, lib, ... }:

{
  # Enable mDNS/Avahi so .local names resolve inside the VM.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;

    # Force Avahi to bind on the bridge (lan-br) and the main uplink (enp0s1)
    # and *publish* records; the packaged default config disables publishing.
    # interfaces = [ "lan-br" "enp0s1" ];
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
      domain = true;
      hinfo = true;
      userServices = true;
    };
  };

  # Ensure systemd-resolved handles mDNS/LLMNR; keep DNSSEC permissive for LAN.
  services.resolved = {
    enable = lib.mkDefault true;
    dnssec = lib.mkDefault "false";
    domains = lib.mkDefault [
      "lan"
      "local"
    ];
    extraConfig = lib.mkDefault ''
      MulticastDNS=yes
      LLMNR=yes
    '';
  };
}
