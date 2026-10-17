# The operator-facing ssh names of the fleet, in one place: the ssh client config (home-manager
# ssh-tailnet-hosts.nix) renders its stanzas from them, and the switch verbs (ndh-switch, fleet-switch) reach the
# machines by them, so the name a switch dials is the name the operator types.
{ lib, catalog }:
let
  tailnetDomain =
    if catalog ? netplan && catalog.netplan ? tailnet then catalog.netplan.tailnet.domain else "";
  tailnetAlias = host: if tailnetDomain != "" then "${host}${tailnetDomain}" else null;
  # LAN domain from the catalog (single source, dotted `.lan`) — same guarded
  # shape as tailnetDomain above, no re-typed literal.
  lanDomain = if catalog ? netplan && catalog.netplan ? lan then catalog.netplan.lan.domain else "";
  lanAlias = host: if lanDomain != "" then "${host}${lanDomain}" else null;
in
{
  inherit
    tailnetDomain
    tailnetAlias
    lanDomain
    lanAlias
    ;

  # `darwin.` still needs its HostName, and that asymmetry is a choice of plane: `darwin.<host>` resolves
  # in its zone to the Mac's HOME-LAN reservation (catalog segment hosts), which answers only while the Mac
  # sits on the home LAN, so the alias keeps the tailnet path for ssh. Its HostName is the FULLY qualified
  # MagicDNS name: a single label goes through the search list, and bioskop has no MagicDNS search domain
  # (measured 2026-10-17: `darwin.nikopol` → `nikopol` did not resolve). `nixos.<host>` is a name WE declare,
  # served by that bare-metal's own dnsmasq in its `.<host>` zone, so it needs none.
  # Each alias with the name its HostName points at (null: none written). The same records render the
  # stanzas and list the aliases checked strictly, so an alias added here cannot miss the strict list.
  operatorAliasesOf = host: [
    {
      service = "darwin";
      hostName =
        if tailnetDomain != "" then
          tailnetAlias host
        else
          throw "ssh-tailnet-hosts: darwin.${host} needs the catalog's tailnet domain for a fully qualified HostName";
    }
    {
      service = "nixos";
      hostName = null;
    }
  ];

  tailnetHostAlias =
    host:
    lib.optional (tailnetDomain != "") {
      name = "${host}-ts";
      hostName = tailnetAlias host;
    };

  hostAliases =
    host:
    lib.filter (x: x != null && x != "") [
      host
      (lanAlias host)
      "${host}.local"
      (tailnetAlias "${host}-ts")
      (tailnetAlias host)
    ];
}
