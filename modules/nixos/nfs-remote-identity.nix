{
  config,
  lib,
  ...
}:
# NixOS wiring for the NFS-remote identity.
#
# Shared declaration: modules/.common.d/nfs-remote-identity.nix
# (option `nfsRemoteIdentity`). This module provisions the group and
# adds the primary user as a member, mirroring the Darwin module so
# both halves of the NFS mesh agree on the gid numeric value.
#
# Once active, NFS exports configured with
# `anonuid=<uid>,anongid=<gid>,root_squash` will squash remote-root
# writes to nxmatic:nfs-remote; legacy files keep their ownership
# until manually chowned.
let
  cfg = config.nfsRemoteIdentity;
  primaryUserName = config.profile.user.name or null;
  hasPrimaryUser = primaryUserName != null && primaryUserName != "";
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        users.groups.${cfg.groupName} = {
          gid = cfg.gid;
        };
      }
      (lib.mkIf (cfg.addPrimaryUserAsMember && hasPrimaryUser) {
        users.users.${primaryUserName}.extraGroups = [ cfg.groupName ];
      })
    ]
  );
}
