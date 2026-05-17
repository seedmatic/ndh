# Nikopol-specific dnsmasq override: forward mammoth-skate.test
# queries to bioskop via SSH tunnel rather than serving locally.
#
# Context: nikopol can be off-LAN (remote location) and needs to
# resolve the closed-world mammoth-skate.test zone by forwarding
# queries through an SSH tunnel to bioskop's dnsmasq (which is the
# authoritative server).  The tunnel forwards local TCP port 5353 to
# bioskop's port 5354 (see modules/home-manager/ssh.d/config.d/mammoth-skate.conf).
#
# This override replaces the `local=/mammoth-skate.test/` directive
# from modules/.common.d/dns-zone-mammoth-skate.nix with a
# `server=/mammoth-skate.test/127.0.0.1#5353` directive, telling
# dnsmasq to forward queries instead of answering authoritatively.
{
  config,
  lib,
  ...
}:
let
  dnsZoneCfg = config.networking.dnsZoneMammothSkateTest;
  zone = config._module.specialArgs.ndh.context.catalog.netplan.lan.zone or "";
in
{
  config = lib.mkIf (dnsZoneCfg.enable && zone != "") {
    environment.etc."dnsmasq.conf".text = lib.mkForce ''
      # Forward .internal queries to the custom DNS proxy
      server=/internal/127.0.0.1#5453

      # Optional: Use these for non-.internal domains
      server=8.8.8.8
      server=8.8.4.4

      # Listen on localhost on an unprivileged port (daemon runs as the
      # primary user — see modules/darwin/dnsmasq.nix UserName/GroupName).
      listen-address=127.0.0.1
      port=5354

      # Don't use /etc/resolv.conf
      no-resolv

      # Enable logging
      log-queries

      # Increase logging verbosity
      log-debug

      # Increase forwarding timeout (default is 5 seconds)
      dns-forward-max=150
      # query-timeout=10

      # ── ${zone} (forwarded via SSH tunnel to bioskop, see modules/home-manager/ssh.d/config.d/mammoth-skate.conf) ─
      server=/${zone}/127.0.0.1#5353
    '';
  };
}
