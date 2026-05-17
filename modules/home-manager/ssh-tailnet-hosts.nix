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
  #   rdp.{host}    → the Darwin host itself (LAN / mDNS)
  #   nixos.{host}  → the NixOS guest VM living on the Darwin host
  # Both present the profile user's rdp-host key+cert so mammoth-skate's
  # TrustedUserCAKeys check accepts the login without per-host key
  # pinning.  The SSH cert *principal* stays `rdp-host` (server-side
  # identity, internal); only the operator-facing alias prefix is `rdp`.
  #
  # `vz.{host}` is intentionally NOT in operatorAliasesForHost
  # because there's no clean generic shape: it only makes sense for
  # hosts that have a separate bare-metal layer (a Tart VM running
  # this nikos config on top of a managed Mac), which today is only
  # nikopol.  Bioskop's "bare metal" IS bioskop — there's no
  # separate VZ host above it.
  #
  # The nikopol-specific alias is defined in two places, depending
  # on which side originates the connection:
  #   - On the nikopol VM itself: a matchBlock in
  #     hosts/nikopol/modules/darwin/vz-host-resolver.nix uses an
  #     ARP-cache resolver to find the bare metal's current IP on
  #     whatever Wi-Fi the laptop is on.
  #   - On every other host: see `vzAliasForBioskopSide` below — a
  #     `ProxyJump=nikopol` block that delegates to the VM's
  #     resolver.
  operatorAliasForService = host: serviceName: hostNameSuffix: ''
    Host ${serviceName}.${host}
      HostName ${host}${hostNameSuffix}
      User ${sshUserForHost host}
      IdentityFile ${config.sshPaths.privKeyFile}
      IdentitiesOnly yes
      IdentityAgent none
      PreferredAuthentications publickey
  '';
  operatorAliasesForHost = host: ''
    ${operatorAliasForService host "rdp" ".local"}
    ${operatorAliasForService host "nixos" "-nixos.local"}
  '';

  # `vz.nikopol` from bioskop / any other operator host: route the
  # connection through the nikopol VM (which is on tailnet) so its
  # local-segment ARP resolver finds the bare metal's current IP.
  # Two-hop: the outer hop is tailnet (bioskop → nikopol), the inner
  # hop is the local-segment hop (nikopol VM → bare metal).
  #
  # ProxyCommand rather than ProxyJump because the nikopol VM has
  # `tailscale set --ssh=true` — Tailscale's built-in SSH server
  # doesn't support stdio-forwarding (the `direct-tcpip` /
  # session-stdio channels that ProxyJump needs internally
  # translate to `ssh -W`).  Tailscale SSH allows interactive
  # sessions and command execution but rejects port-forward
  # channels by design (see tailscale.com docs on SSH features).
  # ProxyCommand sidesteps this by using a regular session-exec to
  # invoke `nc` on the VM, which then opens a plain local-segment
  # TCP connection to the resolved bare-metal IP.
  #
  # The outer-hop alias is `nikopol-ts` rather than `nikopol`
  # because the latter is wired to `HostName ${host}.local`
  # elsewhere in this file's inventory loop, which only resolves
  # when the laptop is at home.  `nikopol-ts` resolves to
  # `nikopol.mammoth-skate.ts.net` and works wherever the laptop
  # currently is.
  #
  # `User stephane.lacoin` and `IdentityFile rdp-host` apply to
  # the inner-hop authentication; the outer ssh hop into nikopol-ts
  # uses whatever `Host nikopol-ts` is configured with elsewhere.
  vzAliasForBioskopSide = ''
    Host vz.nikopol
      ProxyCommand ssh nikopol-ts "nc \$(nikopol-vz-host-resolve-ip) 22"
      User stephane.lacoin
      IdentityFile ${config.sshPaths.privKeyFile}
      IdentitiesOnly yes
      IdentityAgent none
      PreferredAuthentications publickey
  '';

  # The current host's identity, used to gate the bioskop-side
  # vz-host alias: we don't render it ON nikopol itself because the
  # per-host module hosts/nikopol/modules/darwin/vz-host-resolver.nix
  # already provides a matchBlock with the local-ARP resolver shape.
  currentHostName = config._module.specialArgs.profile.host.hostName or "";
  tailnetDomain =
    if ndhContext ? catalog && ndhContext.catalog.netplan ? tailnet then
      ndhContext.catalog.netplan.tailnet.domain
    else
      "";
  tailnetAlias = host: if tailnetDomain != "" then "${host}${tailnetDomain}" else null;
  hostAliases =
    host:
    lib.filter (x: x != null && x != "") [
      host
      "${host}.lan"
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

        Host ${host} ${host}.lan
          HostName ${host}.local

      ''
      + lib.optionalString (tailnetDomain != "") ''
        Host ${host}-ts
          HostName ${tailnetAlias host}
      ''
    ) inventoryHostNames}

    ${lib.optionalString (currentHostName != "nikopol") vzAliasForBioskopSide}
  '';
}
