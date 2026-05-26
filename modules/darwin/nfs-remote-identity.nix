{
  config,
  lib,
  ...
}:
# Darwin wiring for the NFS-remote identity.
#
# The shared declaration lives at modules/.common.d/nfs-remote-identity.nix
# (option `nfsRemoteIdentity`); this module fills in the macOS-specific
# pieces: the group enters the user database via `users.knownGroups` +
# `users.groups.<name>` with an explicit gid (nix-darwin idiom), and the
# primary user is added as a supplementary member via a `dscl` activation
# script.
#
# Why an activation script: nix-darwin's `users.users.<name>` option
# surface is intentionally narrow (createHome, description, gid, home,
# ignoreShellProgramCheck, isHidden, name, openssh, packages, shell,
# uid) — it lacks `extraGroups`, so supplementary group membership on
# macOS has to be managed through Apple's directory service directly.
# `dscl . -append /Groups/<name> GroupMembership <user>` is idempotent
# and the standard pattern — we no-op if the user is already listed.
#
# Once active, NFS exports configured with `-maproot=<uid>:nfs-remote`
# will squash remote-root writes to nxmatic:nfs-remote; legacy files
# owned by `root:wheel` keep their ownership until manually chowned.
let
  cfg = config.nfsRemoteIdentity;
  primaryUserName = config.profile.user.name or null;
  hasPrimaryUser = primaryUserName != null && primaryUserName != "";
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        users.knownGroups = [ cfg.groupName ];
        users.groups.${cfg.groupName} = {
          gid = cfg.gid;
          description = "NFS remote-write marker group (files written through NFS by remote hosts).";
        };
      }
      (lib.mkIf (cfg.addPrimaryUserAsMember && hasPrimaryUser) {
        # Idempotent membership add. `dscl . -append` would duplicate the
        # entry on each run, so check first. Runs after nix-darwin's own
        # users/groups activation has materialized the group record.
        system.activationScripts.postActivation.text = lib.mkAfter ''
          if dscl . -read /Groups/${cfg.groupName} GroupMembership 2>/dev/null \
              | tr ' ' '\n' | grep -qx ${primaryUserName}; then
            : "/Groups/${cfg.groupName} already lists ${primaryUserName}; nothing to do"
          else
            printf '[nfs-remote-identity] adding %s to /Groups/%s\n' \
              ${lib.escapeShellArg primaryUserName} ${lib.escapeShellArg cfg.groupName} >&2
            dscl . -append /Groups/${cfg.groupName} GroupMembership ${primaryUserName} || true
          fi
        '';
      })
    ]
  );
}
