# NixOS-specific nix daemon configuration: trusted-users, sandbox,
# auto-optimise. Substituter + trusted-public-key emission lives in
# modules/.common.d/cache-trust.nix (walks the catalog automatically).
{ config, ... }:
let
  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;
in
{
  nix.settings = {
    auto-optimise-store = false; # Manual optimise keeps build latency predictable during development.
    trusted-users = [
      cfgUserName
      "root"
      "builder" # remote builder user (nerd-nixos VM)
    ];
    # Builds run as the nixbldN users. NixOS emits no build-users-group here, so
    # Nix fell back to a default that depends on the daemon's uid; stated, it is
    # a reviewed fact. Nix takes the group's MEMBERS as build users: only the
    # nixbldN accounts may be members (see the builder user in users.nix).
    build-users-group = "nixbld";
    # The sandbox stays off for now: rke2lab's Maven reactor build needs the
    # network and the host's Maven repository. Until it is made pure, a build
    # reaches the network and what nixbld may read, never what root may.
    sandbox = false;
  };

  nix.extraOptions = ''
    !include /etc/nix/nix.custom.conf
  '';
}
