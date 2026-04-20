{ config, lib, ... }:

{
  # Enable mDNS/Avahi so .local names resolve inside the VM.
  services.avahi = {
    enable = true;
    # Provide NSS bridge for *.local lookups via libc/getaddrinfo.
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

  # Keep systemd-resolved for unicast DNS only.
  # mDNS/LLMNR must be disabled here to avoid duplicate mDNS stacks with Avahi.
  services.resolved = {
    enable = lib.mkDefault true;
    dnssec = lib.mkDefault "false";
    domains = lib.mkDefault [
      "lan"
      "local"
    ];
    extraConfig = lib.mkDefault ''
      MulticastDNS=no
      LLMNR=no
    '';
  };
}
