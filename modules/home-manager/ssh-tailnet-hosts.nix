{ config, lib, pkgs, ... }:
# Modular Tailnet SSH host definitions (@codebase)
# This module encapsulates per-tailnet host client settings using raw extraConfig
# blocks (rather than matchBlocks attrset) to preserve ordering and comments.
# If later we decide to generate dynamically from `tailscale status --json`, we
# can replace the static list with a derivation producing this text.

let
  # Get username from profile configuration
  userMapping = config._module.specialArgs.userMapping;
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;  # Use profile-based username (nxmatic for committed profile)
  committedUserName = userMapping.profileUsers.committed.name;
  workUserName = userMapping.profileUsers.work.name;
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
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 4

    Host bioskop bioskop.lan bioskop.local bioskop-ts bioskop.mammoth-skate.ts.net
      User ${committedUserName}

    Host bioskop bioskop.lan
     HostName bioskop.local

    Host bioskop-ts
      HostName bioskop.mammoth-skate.ts.net

    Host alcide alcide.lan alcide.local alcide-ts alcide.mammoth-skate.ts.net
      User ${workUserName}

    Host alcide alcide.lan
     HostName alcide.local

    Host alcide-ts
      HostName alcide.mammoth-skate.ts.net
  '';
}
