{
  config,
  lib,
  ...
}:
# Shared NFS-remote identity declaration — single source of truth for the
# group used to mark files written via NFS by remote hosts.
#
# Why this exists: NFS over Darwin (`/etc/exports`) and NixOS
# (`/etc/exports.d/...`) carries raw numeric ids. The server-side
# `-maproot=` (Darwin) / `anonuid=,anongid=,all_squash` (NixOS) settings
# squash the remote root to a local user/group pair so files end up
# writable by the operator (nxmatic) on every server.
#
# We squash the GID to a dedicated `nfs-remote` group rather than the
# operator's primary group so that `ls -l` immediately shows whether a
# file came from a remote NFS write — useful for debugging cross-host
# write loops, GitOps mirrors, or stale auto-materialized assets. The
# UID stays the operator's own, so writes are unambiguously owned by
# someone who can also remove them.
#
# Per-platform consumers:
#   - modules/darwin/nfs-remote-identity.nix
#   - modules/nixos/nfs-remote-identity.nix
#
# Mirrors the structure of `nix-store-identity.nix`.
{
  options.nfsRemoteIdentity = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Provision the `nfs-remote` group on this host so NFS exports can
        squash remote-root writes to it.
      '';
    };

    groupName = lib.mkOption {
      type = lib.types.str;
      default = "nfs-remote";
      description = "Name of the dedicated group for NFS-remote-written files.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 30001;
      description = ''
        Numeric GID for the `nfs-remote` group. Must be identical on every
        host that participates in the NFS mesh — NFS carries raw numeric
        ids on the wire. 30001 sits next to the nixbld family (30000),
        well-clear of macOS reserved ranges (<400) and Linux distro
        service ranges (<1000).
      '';
    };

    addPrimaryUserAsMember = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to add the host's primary user (`profile.user.name`) as a
        supplementary member of the `nfs-remote` group. Lets the user
        write to files squashed to that group without sudo.
      '';
    };
  };
}
