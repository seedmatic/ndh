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
  operatorAliasesForHost = host: ''
    Host rdp-host.${host}
      HostName ${host}.local

    Host vz-host.${host}
      HostName ${host}-vz.lan
      User ${sshUserForHost host}
      IdentityFile ${config.sshPaths.privKeyFile}
      IdentitiesOnly yes
      IdentityAgent none
      PreferredAuthentications publickey

    Host nixos.${host}
      HostName ${host}-nixos.local
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
