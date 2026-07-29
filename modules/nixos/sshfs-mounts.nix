{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sshfsMounts;

  # Reliability options shared by every sshfs mount. sshfs rides ONE ssh channel — no nfsd /
  # lockd / statd / mountd / portmapper / stale-handles (the whole NFS surface that hung us). The
  # cert-based CA auth means the key just needs to be a signed identity the remote sshd trusts.
  #   reconnect + ServerAlive*  → survive a dropped link (roaming / hotspot) and re-establish.
  #   cache + kernel_cache      → cut the FUSE+SSH per-op latency (read-mostly worktree/assets).
  #   x-systemd.automount       → mount on first access, not at boot (server may be down).
  #   _netdev + after network   → ordered after the network is up.
  #   idmap=user + uid/gid      → remote files (owned by the operator uid on the Mac) appear as the
  #                               local operator, so reads/writes carry the right identity.
  commonOptions = [
    "x-systemd.automount"
    "x-systemd.idle-timeout=600"
    "x-systemd.mount-timeout=30s"
    "_netdev"
    "allow_other"
    "default_permissions"
    "reconnect"
    "ServerAliveInterval=15"
    "ServerAliveCountMax=3"
    "ConnectTimeout=10"
    "StrictHostKeyChecking=accept-new"
    "compression=no"
    "cache=yes"
    "kernel_cache"
    "idmap=user"
    "uid=${toString cfg.uid}"
    "gid=${toString cfg.gid}"
    "IdentityFile=${cfg.identityFile}"
  ];

  mkFileSystem = mount: {
    name = mount.localPath;
    value = {
      device = "${cfg.remoteUser}@${cfg.remoteHost}:${mount.remotePath}";
      fsType = "sshfs";
      options = commonOptions;
    };
  };
in
{
  options.services.sshfsMounts = {
    enable = lib.mkEnableOption "sshfs mounts replacing the NFS /net automount (reliable single-ssh-channel transport)";

    remoteHost = lib.mkOption {
      type = lib.types.str;
      description = "Host owning the shared trees (the Mac), e.g. nikopol.local.";
    };

    remoteUser = lib.mkOption {
      type = lib.types.str;
      description = "SSH login user on remoteHost that owns the shared trees (the CA-signed identity authenticates as this user).";
    };

    identityFile = lib.mkOption {
      type = lib.types.str;
      description = "Absolute path to the CA-signed private key root uses to authenticate to remoteHost (a system-profile key under /var/lib/ndh/ssh-keys/, root-readable).";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 501;
      description = "Local uid remote files map to (the operator, 501).";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 30001;
      description = "Local gid remote files map to (the nfs-remote/operator group).";
    };

    mounts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            remotePath = lib.mkOption {
              type = lib.types.str;
              description = "Absolute path on remoteHost to share (e.g. /Volumes/git-worktree-store).";
            };
            localPath = lib.mkOption {
              type = lib.types.str;
              description = "Local mountpoint. Keep the /net/<host>/<remotePath> convention so rke2lab's netPrefix is unchanged.";
            };
          };
        }
      );
      default = [ ];
      description = "The trees to mount from remoteHost over sshfs.";
    };
  };

  config = lib.mkIf cfg.enable {
    # sshfs + fuse must be on the system path for the fileSystems mount helper.
    system.fsPackages = [ pkgs.sshfs ];
    programs.fuse.userAllowOther = true;

    fileSystems = builtins.listToAttrs (map mkFileSystem cfg.mounts);
  };
}
