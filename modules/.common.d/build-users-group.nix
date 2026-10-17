{
  config,
  lib,
  pkgs,
  ...
}:
# Only the build users (nixbldN on NixOS, _nixbldN on Darwin) may hold the build-users-group. The nix daemon
# refuses a client whose PRIMARY group it is, trusted or not (nix 2.34 daemon.cc, authPeer), and takes the
# group's members as build users (user-lock.cc, getgrnam's gr_mem).
#
# NixOS names a user's primary group by `group`, nix-darwin by `gid`; NixOS adds members through
# `extraGroups` too. The Darwin activation that removes stray GroupMembers is modules/darwin/build-users-group.nix.
let
  group = config.nix.settings.build-users-group;
  gid = config.ids.gids.${group};
  buildUserPrefix = if pkgs.stdenv.hostPlatform.isDarwin then "_nixbld" else "nixbld";
  buildUser = name: builtins.match "${buildUserPrefix}[0-9]+" name != null;
  others = lib.filterAttrs (name: _: !buildUser name) config.users.users;
  primary = lib.attrNames (
    lib.filterAttrs (_: u: (u.group or null) == group || (u.gid or null) == gid) others
  );
  members = lib.filter (name: !buildUser name) (
    config.users.groups.${group}.members or [ ]
    ++ lib.attrNames (lib.filterAttrs (_: u: lib.elem group (u.extraGroups or [ ])) others)
  );
in
{
  assertions = [
    {
      assertion = primary == [ ];
      message = "build-users-group '${group}' (gid ${toString gid}) is the primary group of ${lib.concatStringsSep ", " primary}: the nix daemon refuses them as clients";
    }
    {
      assertion = members == [ ];
      message = "${lib.concatStringsSep ", " members} would be build users: only the nixbld build users may be members of '${group}'";
    }
  ];
}
