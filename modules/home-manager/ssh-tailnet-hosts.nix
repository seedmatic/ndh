{
  config,
  lib,
  pkgs,
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
  # memory carries between `dig rdp.bioskop.<zone>` and
  # `ssh rdp.bioskop`.
  #
  # The two roles target the same host from two routes:
  #   rdp.{host}    → the Darwin host itself (via MagicDNS)
  #   nixos.{host}  → the NixOS guest VM living on the Darwin host
  # Both present the profile user's rdp-host key+cert so mammoth-skate's
  # TrustedUserCAKeys check accepts the login without per-host key
  # pinning.  The SSH cert *principal* stays `rdp-host` (server-side
  # identity, internal); only the operator-facing alias prefix is `rdp`.
  #
  # `vz.{host}` is intentionally NOT in operatorAliasesForHost
  # because there's no clean generic shape: it only makes sense for
  # hosts that have a separate bare-metal layer (a Tart VM running
  # this nixos config on top of a managed Mac), which today is only
  # nikopol.  Bioskop's "bare metal" IS bioskop — there's no
  # separate VZ host above it.
  #
  # The single nikopol-specific alias is `vzNikopolAlias` below,
  # rendered uniformly on every managed host — resolution and
  # reachability now ride the per-baremetal split-DNS zone + advertised
  # subnet route (the former per-host ARP resolver is retired).
  # The publickey identity every operator-facing alias presents: the profile
  # user's rdp-host key+cert read straight from disk (IdentityAgent none) so
  # auth never depends on a populated ssh-agent.  Single-sourced here because
  # the bare/.local/-ts host block below must present the SAME identity —
  # otherwise the literal `.local` name (a bringup fallback that does NOT match
  # the rdp./nixos. operator aliases nor the `*.nikopol` zone block) would offer
  # only ~/.ssh/id_rsa and be rejected by the CA-cert sshd.
  operatorIdentityLines = ''
    IdentityFile ${config.sshPaths.privKeyFile}
    IdentitiesOnly yes
    IdentityAgent none
    PreferredAuthentications publickey
  '';
  operatorAliasForService = host: serviceName: hostNameSuffix: ''
    Host ${serviceName}.${host}
      HostName ${host}${hostNameSuffix}
      User ${sshUserForHost host}
      ${operatorIdentityLines}
  '';
  # Operator aliases resolve to the bare MagicDNS name, never `.local`:
  # a `.local` HostName stalls ~5s on macOS — systemd-resolved's mDNS
  # responder sends no NSEC for the absent AAAA, so getaddrinfo waits out
  # the timeout — whereas MagicDNS answers over unicast DNS, instantly.
  operatorAliasesForHost = host: ''
    ${operatorAliasForService host "rdp" ""}
    ${operatorAliasForService host "nixos" "-nixos"}
  '';

  # `vz.nikopol` — the corporate bare-metal Mac hosting the nikopol VM.  It runs
  # no nix-darwin config, so it has no generated stanza of its own; every managed
  # host (the nikopol VM, nikopol-nixos, bioskop, …) reaches it by this one alias.
  #
  # Resolution + reachability are now split-DNS native: the per-baremetal segment
  # dnsmasq holds a `vz.nikopol` host-record (see modules/nixos/baremetal-segment.nix)
  # and the segment's /24 is advertised into the tailnet, so any host with the
  # split-DNS zone resolves `vz.nikopol` and reaches it over the subnet route.  The
  # former ARP ProxyCommand (nikopol-vz-host-resolve-ip) is retired — no ProxyCommand,
  # no `IdentityAgent none`.  `User stephane.lacoin` is the corp account on the bare
  # metal; the operator's rdp-host key is in its authorized_keys.
  vzNikopolAlias = ''
    Host vz.nikopol
      User stephane.lacoin
      IdentityFile ${config.sshPaths.privKeyFile}
      IdentitiesOnly yes
      PreferredAuthentications publickey
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
        # Policy: use accept-new to reduce friction; tighten to 'yes' if host keys
        # are stabilized via your OpenSSH CA instead of Tailscale SSH rotation.
        ###############################################################################

        # NixOS guest hosts are ephemeral and can rotate host keys; keep them
        # out of persistent known_hosts checks to avoid rebuild interruption.
        Host *-nixos *-nixos.local
          StrictHostKeyChecking no
          UserKnownHostsFile /dev/null
          GlobalKnownHostsFile /dev/null
          CheckHostIP no

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
      + lib.optionalString (tailnetDomain != "") ''
        Host ${host}-ts
          HostName ${tailnetAlias host}
      ''
    ) inventoryHostNames}

    ${vzNikopolAlias}
  '';
}
