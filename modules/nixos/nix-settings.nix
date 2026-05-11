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
      "builder" # remote builder user (nerd-nixos Lima VM)
    ];
    sandbox = false;
    # Sandbox disabled for this profile set; do not force host-local
    # device paths (e.g. /dev/kvm) into evaluated settings, as that
    # breaks evaluation on non-KVM bringup/runtime hosts.
  };

  nix.extraOptions = ''
    !include /etc/nix/nix.custom.conf
  '';
}
