{
  config,
  lib,
  ...
}:
# Only the _nixbldN build users may hold the build-users-group (nixbld). The nix daemon refuses a client
# whose PRIMARY group it is, trusted or not (nix 2.34 daemon.cc, authPeer), and takes the group's members
# as build users (user-lock.cc, getgrnam's gr_mem, i.e. GroupMembership on macOS).
#
# nix-darwin manages nixbld's GroupMembership but not its GroupMembers (the members' GUIDs), so a member
# added by hand there survives every switch: the activation removes any GUID that is not a declared
# member's. Measured 2026-10-17: the operator's account was in bioskop's GroupMembers, not in nikopol's.
let
  group = config.nix.settings.build-users-group;
  gid = config.ids.gids.${group};
  buildUser = name: builtins.match "_nixbld[0-9]+" name != null;
  primary = lib.attrNames (
    lib.filterAttrs (name: u: !buildUser name && (u.gid or null) == gid) config.users.users
  );
  members = config.users.groups.${group}.members or [ ];
  strays = lib.filter (name: !buildUser name) members;
in
{
  assertions = [
    {
      assertion = primary == [ ];
      message = "build-users-group '${group}' (gid ${toString gid}) is the primary group of ${lib.concatStringsSep ", " primary}: the nix daemon refuses them as clients";
    }
    {
      assertion = strays == [ ];
      message = "${lib.concatStringsSep ", " strays} would be build users: only _nixbldN may be members of '${group}'";
    }
  ];

  system.activationScripts.postActivation.text = lib.mkAfter ''
    # Stray GroupMembers of ${group}: only the declared members' GUIDs stay.
    allowed=" ${
      lib.concatMapStringsSep " " (
        name: "$(dscl . -read /Users/${name} GeneratedUID 2>/dev/null | awk '{print $2}')"
      ) members
    } "
    for guid in $(dscl . -read /Groups/${group} GroupMembers 2>/dev/null | sed 's/^GroupMembers://'); do
      case "$allowed" in
        *" $guid "*) ;;
        *)
          printf '[build-users-group] removing a member that is not a build user from %s: %s\n' ${lib.escapeShellArg group} "$guid" >&2
          dscl . -delete /Groups/${group} GroupMembers "$guid" || true
          ;;
      esac
    done
  '';
}
