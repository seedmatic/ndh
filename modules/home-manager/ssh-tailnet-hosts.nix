{ config, lib, pkgs, ... }:
# Modular Tailnet SSH host definitions (@codebase)
# This module encapsulates per-tailnet host client settings using raw extraConfig
# blocks (rather than matchBlocks attrset) to preserve ordering and comments.
# If later we decide to generate dynamically from `tailscale status --json`, we
# can replace the static list with a derivation producing this text.

let
  # Get username from profile configuration
  profile = config._module.specialArgs.profile;
  userName = profile.user.name;  # Use profile-based username (nxmatic for committed profile)
in
{
  programs.ssh.extraConfig = lib.mkAfter ''
    ###############################################################################
    # Tailnet Hosts (modular file ssh-tailnet-hosts.nix) (@codebase)
    # Generated/maintained list of Tailscale (MagicDNS) hosts.
    # Policy: use accept-new to reduce friction; tighten to 'yes' if host keys
    # are stabilized via your OpenSSH CA instead of Tailscale SSH rotation.
    ###############################################################################

    Host bioskop bioskop.mammoth-skate.ts.net bioskop-ts
      HostName bioskop.mammoth-skate.ts.net
      User ${userName}
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ~/.ssh/known_hosts
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 4

    Host bioskop-nixos bioskop-nixos.mammoth-skate.ts.net bioskop-nixos-ts
      HostName bioskop-nixos.mammoth-skate.ts.net
      User ${userName}
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ~/.ssh/known_hosts
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 4

    Host bioskop-controlplane bioskop-controlplane.mammoth-skate.ts.net bioskop-controlplane-ts
      HostName bioskop-controlplane.mammoth-skate.ts.net
      User ${userName}
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ~/.ssh/known_hosts
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 4

    Host alcide alcide.mammoth-skate.ts.net alcide-ts
      HostName alcide.mammoth-skate.ts.net
      User ${userName}
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ~/.ssh/known_hosts
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 4

    # Catch-all for any future tailnet hosts (fallback user + relaxed key policy)
    Host *.mammoth-skate.ts.net
      User ${userName}
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ~/.ssh/known_hosts
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 4
  '';
}
