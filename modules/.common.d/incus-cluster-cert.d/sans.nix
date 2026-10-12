# The SAN set of the Incus CLUSTER certificate — computed at evaluation, from the catalog.
#
# ONE certificate serves every member (`incus cluster update-certificate` installs it
# everywhere), so the SAN is the WHOLE FLEET's: each member's `nixosHostname`, its
# `fabricFqdn`, `<hostname>.local` for mDNS, `<hostname>.<domain>` for every domain the
# catalog declares, its fabric gateway and lan-br link end, and every segment gateway it owns
# (the per-cluster vmnet /21s, how a node reaches its host's Incus engine). The tailnet is a
# NAME only: a tailnet address is assigned, not declared, so a certificate built on today's
# value would be wrong after a renew.
#
# A member without a name, or without a segment gateway, is FATAL: a cluster certificate that
# silently omits one member reads as success everywhere and fails on that member by name.
{ lib, netplan }:
let
  baremetal = netplan.baremetal;
  members = lib.attrNames baremetal;

  suffixes = lib.filter (d: d != "") (
    map (net: lib.removePrefix "." (if lib.isAttrs net then net.domain or "" else "")) (
      lib.attrValues netplan
    )
  );

  isAddress = v: builtins.match "[0-9a-fA-F:.]+" v != null;

  memberSans =
    host:
    let
      bm = baremetal.${host};
      hostname = bm.nixosHostname or (throw "incus cluster cert: ${host} has no nixosHostname");
      fqdn = bm.fabricFqdn or (throw "incus cluster cert: ${host} has no fabricFqdn");
      addresses = lib.filter (v: v != null && v != "") [
        (bm.netGateway or null)
        (bm.hostAddress or null)
      ];
    in
    [
      hostname
      fqdn
      "${hostname}.local"
    ]
    ++ map (s: "${hostname}.${s}") suffixes
    ++ addresses;

  segmentGateways =
    host:
    let
      gateways = lib.filter isAddress (
        map (s: s.gateway or "") (
          lib.filter (s: lib.hasPrefix "${host}-" (s.name or "")) (netplan.segments or [ ])
        )
      );
    in
    if gateways == [ ] then throw "incus cluster cert: no segment gateway for ${host}" else gateways;
in
lib.unique (
  lib.concatMap memberSans members
  ++ [
    "127.0.0.1"
    "::1"
  ]
  ++ lib.concatMap segmentGateways members
)
