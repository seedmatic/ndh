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
  # The historical `vz-host.{host}` alias was retired: it pointed at
  # `{host}-vz.lan`, but bioskop has no separate VZ host (the Mac runs
  # bioskop directly) and nikopol's bare-metal Mac is on a company-
  # managed network the bbox can't resolve.  Neither alias resolved
  # to anything useful.
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
  '';
}
