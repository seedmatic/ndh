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
  catalog = config._module.specialArgs.catalog;
  profile = config._module.specialArgs.profile;
  userName = profile.user.name; # Use profile-based username (nxmatic for committed profile)
  committedUserName = catalog.users.committed.name;
  workUserName = catalog.users.work.name;
  tailnetDomain =
    if
      (config._module.specialArgs ? catalog) && (config._module.specialArgs.catalog.networks ? tailnet)
    then
      config._module.specialArgs.catalog.networks.tailnet.domain
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

        Host *
          StrictHostKeyChecking accept-new
          UserKnownHostsFile ~/.ssh/known_hosts
          ServerAliveInterval 30
          ServerAliveCountMax 4

        Host ${lib.concatStringsSep " " (hostAliases "bioskop")}
          User ${committedUserName}

        Host bioskop bioskop.lan
         HostName bioskop.local

    ${lib.optionalString (tailnetDomain != "") ''
      Host bioskop-ts
        HostName ${tailnetAlias "bioskop"}
    ''}

        Host ${lib.concatStringsSep " " (hostAliases "alcide")}
          User ${committedUserName}

        Host alcide alcide.lan
         HostName alcide.local

    ${lib.optionalString (tailnetDomain != "") ''
      Host alcide-ts
        HostName ${tailnetAlias "alcide"}
    ''}
  '';
}
