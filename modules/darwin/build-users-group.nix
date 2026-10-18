{
  config,
  lib,
  ...
}:
# The guard on the build-users-group (nixbld) is common: modules/.common.d/build-users-group.nix.
#
# nix-darwin manages nixbld's GroupMembership but not its GroupMembers (the members' GUIDs), so a member
# added by hand there survives every switch: the activation removes any GUID that is not a declared
# member's. Measured 2026-10-17: the operator's account was in bioskop's GroupMembers, not in nikopol's.
let
  group = config.nix.settings.build-users-group;
  members = config.users.groups.${group}.members or [ ];
in
{
  # Only with declared members, and only when every one of their GUIDs is read: an empty allow-list would
  # delete every GUID, the build users' included, and break every build on that Mac.
  system.activationScripts.postActivation.text = lib.mkIf (members != [ ]) (
    lib.mkAfter ''
      # Stray GroupMembers of ${group}: only the declared members' GUIDs stay.
      allowed=" " unread=""
      for name in ${lib.escapeShellArgs members}; do
        guid=$(dscl . -read "/Users/$name" GeneratedUID 2>/dev/null | awk '{print $2}')
        if [ -n "$guid" ]; then allowed="$allowed$guid "; else unread="$unread $name"; fi
      done
      if [ -n "$unread" ]; then
        printf '[build-users-group] no GUID for%s: %s GroupMembers left untouched\n' "$unread" ${lib.escapeShellArg group} >&2
      else
        for guid in $(dscl . -read /Groups/${group} GroupMembers 2>/dev/null | sed 's/^GroupMembers://'); do
          case "$allowed" in
            *" $guid "*) ;;
            *)
              printf '[build-users-group] removing a member that is not a build user from %s: %s\n' ${lib.escapeShellArg group} "$guid" >&2
              dscl . -delete /Groups/${group} GroupMembers "$guid" || true
              ;;
          esac
        done
      fi
    ''
  );
}
