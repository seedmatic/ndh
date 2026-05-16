# DNS zone `mammoth-skate.test` — closed-world LAN zone served by
# bioskop's dnsmasq.  RFC 6761 reserves `.test` permanently for
# private/test use, so we never collide with a publicly delegated
# name.
#
# Vocabulary:
#   zone apex          = `mammoth-skate.test` itself.  No record at
#                        the apex; queries for the bare zone name
#                        return NXDOMAIN.
#   top-level hosts    = catalog entries with no `parent` (`bioskop`,
#                        `nikopol`).  Always the RDP-able Macs.
#   nested hosts       = catalog entries with a `parent` (Tart NixOS
#                        guests, RKE2 nodes, the bare-metal VZ
#                        bridge).
#
# Closed-world: dnsmasq is told `local=/mammoth-skate.test/` so any
# query for a name in this zone NOT explicitly listed below resolves
# to NXDOMAIN.  Queries are NEVER forwarded upstream — privacy-safe
# (no leak of private hostnames to external resolvers) and
# fail-fast (typos surface immediately).
#
# FQDN composition (uniform for every emitted record):
#
#     <service>.<host>.mammoth-skate.test
#
# where:
#   - host    = the top-level host's catalog key.  Either the
#               entry's own key (top-level) or its `parent`.
#   - service = derived from the entry's `kind`:
#                 darwin-host → "rdp-host"
#                 nixos       → "nixos"
#                 vz-host     → "vz-host"
#                 rke2        → "<role>.rke2"  (role is mandatory)
#                 wifi-iface  → skipped (no record)
#
# This naming mirrors the SSH alias convention from
# modules/home-manager/ssh-tailnet-hosts.nix verbatim, so
# `dig rdp-host.bioskop.mammoth-skate.test`
# and
# `ssh rdp-host.bioskop`
# resolve to identical names.
#
# Top-level hosts also get a CNAME from `<key>.<zone>` to the
# canonical `rdp-host.<key>.<zone>` so muscle-memory
# `dig bioskop.mammoth-skate.test` resolves.  Nested hosts do not
# get aliases — only the structured form is emitted.
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  ndhContext = ndh.context;
  catalog = ndhContext.catalog;
  netplan = catalog.netplan or { };
  lan = netplan.lan or { };
  zone = lan.zone or "";
  hosts = lan.hosts or { };

  # Per-kind shape: how to compose the FQDN service prefix and
  # whether to emit at all.
  kindShape = {
    darwin-host = {
      emit = true;
      service = _entry: "rdp-host";
    };
    nixos = {
      emit = true;
      service = _entry: "nixos";
    };
    vz-host = {
      emit = true;
      service = _entry: "vz-host";
    };
    rke2 = {
      emit = true;
      # RKE2 entries must carry a `role`; renderer fails loudly
      # otherwise so a missing role doesn't silently land an entry
      # at `.rke2.<parent>.<zone>`.
      service =
        entry:
        if entry ? role && entry.role != null && entry.role != "" then
          "${entry.role}.rke2"
        else
          throw "dns-zone-mammoth-skate: kind=rke2 entry needs a `role` (got: ${
            builtins.toJSON entry
          })";
    };
    wifi-iface = {
      emit = false;
    };
  };

  # Top-level host (no parent) → key is the host segment of the FQDN.
  # Nested host (parent set)   → parent is the host segment.
  hostSegment =
    name: entry:
    if entry ? parent && entry.parent != null && entry.parent != "" then entry.parent else name;

  # Render a catalog entry to {fqdn, ip} or null if its kind is
  # not emitted.  Throws if `kind` is unknown (forces operator to
  # extend `kindShape` rather than silently dropping records).
  renderEntry =
    name: entry:
    let
      shape =
        kindShape.${entry.kind} or (throw "dns-zone-mammoth-skate: unknown kind '${entry.kind}' on entry '${name}'");
    in
    if !shape.emit then
      null
    else
      {
        inherit name;
        fqdn = "${shape.service entry}.${hostSegment name entry}.${zone}";
        ip = entry.ip;
      };

  # Apply renderEntry, drop nulls (skipped kinds).
  emittedRecords = lib.filter (r: r != null) (lib.mapAttrsToList renderEntry hosts);

  # Top-level hosts that get a CNAME alias `<key>.<zone>` →
  # `rdp-host.<key>.<zone>`.
  aliasRecords = lib.mapAttrsToList (name: entry: {
    inherit name;
    alias = "${name}.${zone}";
    canonical = "rdp-host.${name}.${zone}";
  }) (lib.filterAttrs (_: e: !(e ? parent) || e.parent == null || e.parent == "") hosts);

  # The addn-hosts file dnsmasq parses for the A records.  Format:
  # one `<ip>  <fqdn>` per line.  `addn-hosts` only takes A/AAAA
  # records, never CNAMEs (those go in the conf file via `cname=`).
  addnHostsFile = pkgs.writeText "mammoth-skate-test.hosts" (
    lib.concatMapStringsSep "\n" (r: "${r.ip}  ${r.fqdn}") emittedRecords + "\n"
  );

  # Conf snippet pasted into dnsmasq.conf.  The `local=/zone/` line
  # makes dnsmasq authoritative for the zone (no upstream forwarding;
  # NXDOMAIN for any name not in addn-hosts or cname).
  dnsmasqZoneSnippet = ''

    # ── ${zone} (closed-world LAN zone, see modules/.common.d/dns-zone-mammoth-skate.nix) ─
    local=/${zone}/
    addn-hosts=${addnHostsFile}
  ''
  + lib.concatMapStringsSep "\n" (a: "cname=${a.alias},${a.canonical}") aliasRecords
  + "\n"
  # Service-level CNAMEs — point to their current hosting location.
  # During Phase A (bootstrap), headscale runs as a LaunchAgent on
  # bioskop.  During Phase B (production), update the target to the
  # K8s ingress or service IP once headscale migrates to RKE2.
  + "cname=headscale.${zone},rdp-host.bioskop.${zone}\n";
in
{
  # Surface read-only for any other module that wants to inspect what
  # was rendered (the dnsmasq config consumer reads this).
  options.networking.dnsZoneMammothSkateTest = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = zone != "" && hosts != { };
      description = ''
        Whether the `mammoth-skate.test` closed-world LAN zone is
        rendered for this host.  Auto-true when both
        `catalog.netplan.lan.zone` and `catalog.netplan.lan.hosts`
        are populated.
      '';
    };

    addnHostsFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = addnHostsFile;
      description = ''
        Path in the Nix store to the rendered addn-hosts file.
        dnsmasq consumes via `addn-hosts=…`.
      '';
    };

    dnsmasqSnippet = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = dnsmasqZoneSnippet;
      description = ''
        Conf snippet to splice into dnsmasq.conf carrying the
        `local=`, `addn-hosts=`, and `cname=` directives for the
        zone.
      '';
    };
  };
}
