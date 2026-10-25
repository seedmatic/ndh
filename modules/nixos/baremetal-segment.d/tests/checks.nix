# Each metalspace's dnsmasq names its darwin host at the catalog's home-LAN reservation, so every tool
# resolves `darwin.<domain>`, and names no corporate bare-metal. Read from the evaluated configurations.
{
  pkgs,
  lib,
  nixosConfigurations,
  catalog,
}:
let
  lanHosts = catalog.netplan.lan.hosts;
  check =
    domain:
    let
      records = nixosConfigurations."${domain}-nixos".config.services.dnsmasq.settings.host-record;
      wanted = "darwin.${domain},${lanHosts.${domain}.ip}";
      corporate = lib.filter (h: (lanHosts.${h}.ownership or "") != "personal") (lib.attrNames lanHosts);
      named = lib.filter (r: lib.any (h: lib.hasInfix h r) corporate) records;
    in
    assert lib.assertMsg (lib.elem wanted records)
      "${domain}-nixos: dnsmasq host-record lacks ${wanted}: ${builtins.toJSON records}";
    assert lib.assertMsg (
      named == [ ]
    ) "${domain}-nixos: dnsmasq names a corporate host: ${builtins.toJSON named}";
    pkgs.runCommand "split-dns-darwin-${domain}" { } "touch $out";
  # The corporate box's screen openings are earned at run time, never loaded: on a foreign vz-host's
  # guest the ruleset names the set EMPTY, exactly one rule reads it, and no service VIP appears as a
  # literal accept — so a widening (a VIP written in, the router added, the set pre-filled) is red.
  services = catalog.netplan.tailnet.services;
  vips = lib.filter (v: v != null) (map (n: services.${n}.vip or null) (lib.attrNames services));
  screens =
    domain:
    let
      bm = catalog.netplan.baremetal.${domain};
      table =
        nixosConfigurations."${domain}-nixos".config.networking.nftables.tables.metalspace-guard.content;
      lines = lib.splitString "\n" table;
      reading = lib.filter (l: lib.hasInfix "@offtailnet_screens" l) lines;
      literal = lib.filter (l: lib.hasInfix "accept" l && lib.any (v: lib.hasInfix v l) vips) lines;
      foreign = (bm.vzHostKind or "") == "foreign";
      hasSet = lib.hasInfix "set offtailnet_screens" table;
      elements = lib.hasInfix "elements" table;
    in
    assert lib.assertMsg (
      foreign == hasSet
    ) "${domain}-nixos: the offtailnet_screens set must exist exactly on a foreign vz-host's guest";
    assert lib.assertMsg (!elements) "${domain}-nixos: offtailnet_screens is pre-filled: ${table}";
    assert lib.assertMsg (builtins.length reading == (if foreign then 1 else 0))
      "${domain}-nixos: expected ${
        if foreign then "one rule" else "no rule"
      } reading the set: ${builtins.toJSON reading}";
    assert lib.assertMsg (
      literal == [ ]
    ) "${domain}-nixos: a service VIP is accepted as a literal: ${builtins.toJSON literal}";
    pkgs.runCommand "offtailnet-screens-${domain}" { } "touch $out";
in
lib.listToAttrs (
  map (domain: lib.nameValuePair "split-dns-darwin-${domain}" (check domain)) (
    lib.attrNames catalog.netplan.baremetal
  )
  ++ map (domain: lib.nameValuePair "offtailnet-screens-${domain}" (screens domain)) (
    lib.attrNames catalog.netplan.baremetal
  )
)
