{ lib, ... }:
{
  # On the nikopol NixOS guest, darwin.nikopol (tailnet address) is unreachable;
  # both hosts share the LAN, so resolve it to the LAN mDNS name instead.
  programs.ssh.extraConfig = lib.mkBefore ''
    Host darwin.nikopol
      HostName nikopol.local
  '';
}
