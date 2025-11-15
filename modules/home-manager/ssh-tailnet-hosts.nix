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
    #
    # Structure: First block defines common settings for all name patterns,
    # then separate blocks define HostName resolution for different contexts.
    ###############################################################################

    # bioskop - Darwin host
    Host bioskop bioskop.lan bioskop.local bioskop-ts bioskop.mammoth-skate.ts.net
      User ${userName}
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ~/.ssh/known_hosts
      IdentityFile ~/.ssh/keys.d/mammoth-skate
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 4

    Host bioskop bioskop.lan
      HostName bioskop.local

    Host bioskop-ts
      HostName bioskop.mammoth-skate.ts.net

    # bioskop-nixos - Lima VM
    Host bioskop-nixos bioskop-nixos.local bioskop-nixos-ts bioskop-nixos.mammoth-skate.ts.net
      User ${userName}
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ~/.ssh/known_hosts
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 4

    Host bioskop-nixos
      HostName bioskop-nixos.local

    Host bioskop-nixos-ts
      HostName bioskop-nixos.mammoth-skate.ts.net

    # bioskop-controlplane - Incus container
    Host bioskop-controlplane bioskop-controlplane.local bioskop-controlplane-ts bioskop-controlplane.mammoth-skate.ts.net
      User ${userName}
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ~/.ssh/known_hosts
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 4

    Host bioskop-controlplane
      HostName bioskop-controlplane.local

    Host bioskop-controlplane-ts
      HostName bioskop-controlplane.mammoth-skate.ts.net

    # alcide - Darwin laptop
    Host alcide alcide.lan alcide.local alcide-ts alcide.mammoth-skate.ts.net
      User ${userName}
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ~/.ssh/known_hosts
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 4

    Host alcide alcide.lan
      HostName alcide.local

    Host alcide-ts
      HostName alcide.mammoth-skate.ts.net

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
