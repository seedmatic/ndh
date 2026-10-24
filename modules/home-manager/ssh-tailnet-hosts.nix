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
  inherit
    (import ../.common.d/operator-aliases.nix {
      inherit lib;
      catalog = ndhContext.catalog or { };
    })
    lanDomain
    tailnetDomain
    tailnetAlias
    operatorAliasesOf
    tailnetHostAlias
    hostAliases
    ;
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
  #   nikopol-nixos.mammoth-skate.ts.net  -> its 100.x        MagicDNS, only when FULLY qualified (the
  #                                                           address changes when the machine re-registers)
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
  # `darwin.` still needs its HostName: see operatorAliasesOf in modules/.common.d/operator-aliases.nix, the
  # one definition of these names, which the switch verbs dial too.
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

  # The vz-recover key's path to each foreign vz-host (roles × keys): that account forces ndh-vz-recover on
  # the key, five verbs, so any session may call `ssh vzrecover.<domain> <verb> [vm]` once `probe` has
  # answered exactly ndh-vz-recover's marker (anything else: the forced command is not in force), and this block alone
  # names the key file (sessions are denied reading it). One identity, no agent, publickey only, so no other
  # key that account trusts is ever offered: IdentityFile accumulates over every matching block, so this one
  # comes before any block that adds one, which the vz-recover-ssh-alias check holds. It uses no control socket
  # (vzNoMultiplexing below). The
  # host key is the one the operator read on that machine, pinned strictly under this alias alone: a
  # foreign vz-host presents no fleet certificate. The fleet's KnownHostsCommand still applies (the leading
  # `Host *` sets it first), but it vouches for the fleet's names only, which this alias is not. Placed
  # before this file's `Host *`, whose values would win otherwise.
  vzRecoverAliases = lib.concatMapStrings (bm: ''
    Host vzrecover.${bm.domain}
      HostName vzhost.${bm.domain}
      User ${bm.vzHostUser}
      IdentityFile ~/.ssh/vz-recover
      IdentitiesOnly yes
      IdentityAgent none
      PreferredAuthentications publickey
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      BatchMode yes
      RequestTTY no
      ForwardAgent no
      ClearAllForwardings yes
      HostKeyAlias vzrecover.${bm.domain}
      StrictHostKeyChecking yes
      UserKnownHostsFile ${pkgs.writeText "vzrecover-${bm.domain}-known-hosts" "vzrecover.${bm.domain} ${bm.vzHostKey}\n"}
      GlobalKnownHostsFile /dev/null
      UpdateHostKeys no

  '') (lib.filter (bm: bm.vzHostKind == "foreign") (lib.attrValues catalog.netplan.baremetal));

  # The vz-recover alias uses no control socket at all. vzhost.<domain> reaches the same host, port and user, so
  # ssh's %C gave both ONE socket, and a vz-recover call rode the master the operator's own key had opened there,
  # an unrestricted shell (measured on nikopol, 2026-10-17). `ControlMaster no` alone still joins an existing
  # master; `ControlPath none` is what keeps it off. vzhost.<domain> may keep multiplexing: this alias never opens
  # a master it could join. In config.d, which the generated config includes before ssh.nix's `Host *`, since the
  # first value wins and that `Host *` would win over any block after it.
  vzNoMultiplexing = lib.concatMapStrings (bm: ''
    Host vzrecover.${bm.domain}
      ControlMaster no
      ControlPath none
  '') (lib.filter (bm: bm.vzHostKind == "foreign") (lib.attrValues catalog.netplan.baremetal));

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

  # One Screen Sharing bookmark per OTHER seat, by its fully qualified tailnet name only, the
  # HostName `darwin.<host>` already uses. Never a home-LAN address: off-site, a hotspot can be
  # 192.168.1.0/24 too, and `192.168.1.x` then routes into it, so the operator would type the
  # Mac's credentials into a stranger's machine (measured 2026-10-24). The tailnet name routes
  # through WireGuard wherever the seat sits.
  screenBookmarks = lib.listToAttrs (
    map (host: {
      name = "Desktop/Screens/${host}.vncloc";
      value.text = ''
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>URL</key>
          <string>vnc://${tailnetAlias host}</string>
        </dict>
        </plist>
      '';
    }) (lib.filter (host: host != profile.host.hostName) inventoryHostNames)
  );
in
{
  home.file = {
    ".ssh/config.d/no-multiplexing.conf".text = vzNoMultiplexing;
  }
  // lib.optionalAttrs (pkgs.stdenv.isDarwin && tailnetDomain != "") screenBookmarks;

  programs.ssh.extraConfig = lib.mkAfter ''
        ###############################################################################
        # Tailnet Hosts (modular file ssh-tailnet-hosts.nix) (@codebase)
        # Generated/maintained list of Tailscale (MagicDNS) hosts.
        ###############################################################################

    ${vzRecoverAliases}
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
