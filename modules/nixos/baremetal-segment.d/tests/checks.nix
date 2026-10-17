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
in
lib.listToAttrs (
  map (domain: lib.nameValuePair "split-dns-darwin-${domain}" (check domain)) (
    lib.attrNames catalog.netplan.baremetal
  )
)
