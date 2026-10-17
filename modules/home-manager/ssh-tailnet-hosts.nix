{
  config,
  osConfig ? { },
  lib,
  pkgs,
  self,
  ...
}:
# Modular Tailnet SSH host definitions (@codebase)
# This module encapsulates per-tailnet host client settings using raw extraConfig
# blocks (rather than matchBlocks attrset) to preserve ordering and comments.
# If later we decide to generate dynamically from `tailscale status --json`, we
# can replace the static list with a derivation producing this text.

let
  # Get username from profile configuration
  ndhContext = config._module.specialArgs.ndh.context;
  catalog = ndhContext.catalog;
  inventory = ndhContext.inventory;
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;
  catalogUserName = catalog.user.name;
  inventoryHostNames = builtins.attrNames (inventory.hosts or { });
  sshUserForHost = _host: catalogUserName;
  # Canonical operator alias layout: `{service}.{host}` with consistent auth.
  # Service names match the headscale `dns.extra_records` namespace
  # (catalog.netplan.tailnet.hosts.<host>.serviceNames), so muscle
  # memory carries between `dig darwin.bioskop.<zone>` and
  # `ssh darwin.bioskop`.
  #
  # The two roles target the same host from two routes:
  #   darwin.{host} → the darwin host (via MagicDNS)
  #   nixos.{host}  → the NixOS guest of the same bare-metal (on bioskop it runs on
  #                   the darwin host; on nikopol beside it, on the corporate bare-metal)
  # Both present the profile user's rdp-host key+cert so mammoth-skate's
  # TrustedUserCAKeys check accepts the login without per-host key
  # pinning.  The SSH cert *principal* stays `rdp-host` (server-side
  # identity, internal); only the operator-facing alias prefix is `darwin`.
  #
  # `vzhost.{host}` is intentionally NOT in operatorAliasesForHost
  # because there's no clean generic shape: it only makes sense for
  # a darwin host that is itself a macOS guest of a separate
  # bare-metal, which today is only nikopol.  bioskop is its own
  # bare-metal and vz-host, reached as `darwin.bioskop`.
  #
  # The single nikopol-specific alias is `vzhostNikopolAlias` below,
  # rendered uniformly on every managed host — resolution and
  # reachability now ride the per-metalspace split-DNS zone + advertised
  # subnet route (the former per-host ARP resolver is retired).
  # The publickey identity every operator-facing alias presents: the profile
  # user's rdp-host key+cert read straight from disk (IdentityAgent none) so
  # auth never depends on a populated ssh-agent.  Single-sourced here because
  # the bare/.local/-ts host block below must present the SAME identity —
  # otherwise the literal `.local` name (a bringup fallback that does NOT match
  # the darwin./nixos. operator aliases nor the `*.nikopol` zone block) would fall
  # through to OpenSSH's built-in default identities (none of which carry the
  # rdp-host key+cert) and be rejected by the CA-cert sshd.
  operatorIdentityLines = ''
    IdentityFile ${config.sshPaths.privKeyFile}
    IdentitiesOnly yes
    IdentityAgent none
    PreferredAuthentications publickey
  '';
  # `hostName = null` means the alias name IS the resolvable name, so NO HostName is written. That is
  # not a shortcut: a HostName restating a name DNS already answers is a second place that name lives,
  # and the two can then disagree — which is exactly what happened here.
  operatorAliasForService =
    host: serviceName: hostName:
    lib.concatStringsSep "\n" (
      [ "Host ${serviceName}.${host}" ]
      ++ lib.optional (hostName != null) "  HostName ${hostName}"
      ++ [
        "  User ${sshUserForHost host}"
        operatorIdentityLines
      ]
    );
  # Operator aliases resolve over UNICAST DNS, never `.local`: a `.local` HostName stalls ~5s on macOS
  # — systemd-resolved's mDNS responder sends no NSEC for the absent AAAA, so getaddrinfo waits out the
  # timeout.
  #
  # ⚠️ But NOT via the bare MagicDNS name, which is what this did and why `ssh nixos.nikopol` broke.
  # Measured 2026-10-01 from bioskop, with getaddrinfo (what ssh calls) and not `dig` (which asks
  # MagicDNS directly and therefore cannot see this at all):
  #
  #   nikopol-nixos                       -> 192.168.1.34     the LAN resolver, via the `lan` search domain
  #   nixos.nikopol                       -> 172.16.16.1      our own dnsmasq, the fabric address
  #   nikopol-nixos.mammoth-skate.ts.net  -> 100.106.165.29   MagicDNS, only when FULLY qualified
  #
  # A single-label name gets the search list applied, so `lan` answers before MagicDNS ever does — the
  # alias was pointing at whatever the home LAN happens to call that name, and earlier at nothing at
  # all.
  #
  # So the `nixos.` alias overrides NOTHING: `nixos.<host>` is a name WE declare, served by that
  # bare-metal's own dnsmasq in its `.<host>` zone, and it is the same name the Incus listener
  # certificate carries. It resolves on its own (measured above), so the block exists only for the User
  # and the identity.
  #
  # `darwin.` still needs its HostName, and that asymmetry is the measurement, not a style choice:
  # `darwin.<host>` does not resolve at all, while `nixos.<host>` does. One alias names a target DNS knows
  # nothing about; the other names a target DNS already answers for.
  # Each alias with the name its HostName points at (null: none written). The same records render the
  # stanzas and list the aliases checked strictly, so an alias added here cannot miss the strict list.
  operatorAliasesOf = host: [
    {
      service = "darwin";
      hostName = host;
    }
    {
      service = "nixos";
      hostName = null;
    }
  ];
  operatorAliasesForHost =
    host:
    lib.concatMapStringsSep "\n" (alias: operatorAliasForService host alias.service alias.hostName) (
      operatorAliasesOf host
    )
    + "\n";

  # The corporate bare-metal Mac hosting the nikopol VM. It runs no nix-darwin config, so it
  # has no generated stanza of its own; every managed host (the nikopol VM, nikopol-nixos,
  # bioskop, …) reaches it by this one.
  #
  # TWO names, one stanza, because they are two PATHS to the same machine and each resolves
  # differently — so neither is redundant:
  #
  #   vzhost.<domain>          the segment name. The per-metalspace dnsmasq holds a host-record
  #                            for it (modules/nixos/baremetal-segment.nix) and the segment is
  #                            advertised into the tailnet, so this is the path that works from
  #                            ANYWHERE, including off-site. It is also the path that does not
  #                            exist yet during a first bringup, or for as long as a renumbering
  #                            has not propagated.
  #   <lanName>.lan            the home-LAN name, served by the LAN's own DNS. Works only on the
  #                            LAN, but works BEFORE the segment does — which is what the first
  #                            materialisation of nerd-nixos on that Mac needs
  #                            (`nix run .#nerd-tart-nikopol-deploy -- <lanName>.lan`), and what
  #                            the baremetal-link deploy falls back to.
  #
  # Do NOT collapse them by giving the first a `HostName` pointing at the second: the LAN name
  # does not resolve for a remote peer, which is the entire reason the segment path exists.
  #
  # Both names and the login come from the catalog — the same entry the deploy app reads, so the
  # operator's path and the automated one cannot drift. The former ARP ProxyCommand
  # (nikopol-vz-host-resolve-ip) is retired: no ProxyCommand, no `IdentityAgent none`.
  vzhostNikopolAlias =
    let
      bm = catalog.netplan.baremetal.nikopol;
    in
    ''
      Host vzhost.${bm.domain} ${bm.vzHostLanName}${catalog.netplan.lan.domain}
        User ${bm.vzHostUser}
        IdentityFile ${config.sshPaths.privKeyFile}
        IdentitiesOnly yes
        PreferredAuthentications publickey
    '';

  # `nerd-nixos` — the NixOS guest materialised as a Tart VM on a bare-metal Mac
  # (on each vz-host, before it becomes `<seat>-nixos`).  It is not an inventory host (a guest, not a managed
  # Darwin host), so the per-host loop above never emits it; this single alias is
  # rendered uniformly on every managed host.  Reached by its mDNS `.local` name
  # because the guest carries no MagicDNS/tailnet alias of its own during bring-up.
  # `User root` + the operator rdp-host key/cert; the `*-nixos` wildcard block above
  # already relaxes known_hosts for it (host keys rotate across re-materialisation).
  # The `IdentityFile none` reset clears the default identities accumulated by the
  # `Host *` blocks so IdentitiesOnly offers only the rdp-host key.
  nerdNixosAlias = ''
    Host nerd-nixos
      HostName nerd-nixos.local
      User root
      IdentityFile none
      IdentityFile ${config.sshPaths.privKeyFile}
      IdentitiesOnly yes
  '';

  tailnetDomain =
    if ndhContext ? catalog && ndhContext.catalog.netplan ? tailnet then
      ndhContext.catalog.netplan.tailnet.domain
    else
      "";
  tailnetAlias = host: if tailnetDomain != "" then "${host}${tailnetDomain}" else null;
  # LAN domain from the catalog (single source, dotted `.lan`) — same guarded
  # shape as tailnetDomain above, no re-typed literal.
  lanDomain =
    if ndhContext ? catalog && ndhContext.catalog.netplan ? lan then
      ndhContext.catalog.netplan.lan.domain
    else
      "";
  lanAlias = host: if lanDomain != "" then "${host}${lanDomain}" else null;
  tailnetHostAlias =
    host:
    lib.optional (tailnetDomain != "") {
      name = "${host}-ts";
      hostName = tailnetAlias host;
    };
  # ssh matches a Host line against the alias, never its HostName: an alias to a fleet machine is strict
  # only when listed itself. The system's aliases too (nix-store.<peer>), which this file's `Host *`
  # would otherwise shadow for the operator.
  fleetAliases =
    map (alias: alias.name) (
      lib.filter
        (
          alias: lib.elem (if alias.hostName == null then alias.name else alias.hostName) self.fleetHostNames
        )
        (
          lib.concatMap (
            host:
            map (alias: {
              name = "${alias.service}.${host}";
              inherit (alias) hostName;
            }) (operatorAliasesOf host)
            ++ tailnetHostAlias host
          ) inventoryHostNames
        )
    )
    ++ (osConfig.opensshPolicy.fleetHostAliases or [ ]);
  hostAliases =
    host:
    lib.filter (x: x != null && x != "") [
      host
      (lanAlias host)
      "${host}.local"
      (tailnetAlias "${host}-ts")
      (tailnetAlias host)
    ];
in
{
  programs.ssh.extraConfig = lib.mkAfter ''
        ###############################################################################
        # Tailnet Hosts (modular file ssh-tailnet-hosts.nix) (@codebase)
        # Generated/maintained list of Tailscale (MagicDNS) hosts.
        ###############################################################################

        # Every fleet name presents a certificate from the host authority, which
        # KnownHostsCommand and /etc/ssh/ssh_known_hosts trust for these names only:
        # a renewed key still verifies, so they are checked strictly, and an unknown
        # key there is refused instead of pinned. So are the aliases to them, and the
        # NixOS guests' names.
        Host ${lib.concatStringsSep " " (lib.unique (self.fleetHostNames ++ fleetAliases))}
          StrictHostKeyChecking yes
          UserKnownHostsFile /dev/null
          UpdateHostKeys no

        Host *-nixos *-nixos.local
          StrictHostKeyChecking yes

        Host *
          StrictHostKeyChecking accept-new
          UserKnownHostsFile ~/.ssh/known_hosts
          ServerAliveInterval 30
          ServerAliveCountMax 4

    ${lib.concatMapStringsSep "\n" (
      host:
      ''
        ${operatorAliasesForHost host}

        Host ${lib.concatStringsSep " " (hostAliases host)}
          User ${sshUserForHost host}
          ${operatorIdentityLines}

        Host ${host} ${host}${lanDomain}
          HostName ${host}

      ''
      + lib.concatMapStrings (alias: ''
        Host ${alias.name}
          HostName ${alias.hostName}
      '') (tailnetHostAlias host)
    ) inventoryHostNames}

    ${vzhostNikopolAlias}
    ${nerdNixosAlias}
  '';
}
