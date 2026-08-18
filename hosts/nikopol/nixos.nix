{
  config,
  lib,
  ...
}:
{
  config = {
    profile.user.home = lib.mkForce "/home/${config.profile.user.name}";

    # Vector observability agent forwards build events to Darwin aggregator
    bringupObserve = {
      enable = true;
      # Forward to Darwin host Vector aggregator via VM network gateway
      # VM NAT makes the macOS host accessible at 192.168.5.2
      upstreamEndpoint = "http://192.168.5.2:9001";
    };

    # sshfs mounts of the Darwin-side git store (replaces the old NFS /net automount).
    # Root executes the mount but authenticates as nxmatic — the operator who owns the
    # trees — via the CA-signed rdp-host key; remote files map back to uid/gid 501:30001.
    # nikopol keeps its git trees on dedicated /Volumes stores.
    services.sshfsMounts = {
      enable = true;
      remoteHost = "nikopol.local";
      remoteUser = "nxmatic";
      identityFile = "/var/lib/ndh/ssh-keys/rdp-host";
      mounts = [
        {
          remotePath = "/Volumes/git-worktree-store";
          localPath = "/net/nikopol.local/Volumes/git-worktree-store";
        }
        {
          remotePath = "/Volumes/git-bare-store";
          localPath = "/net/nikopol.local/Volumes/git-bare-store";
        }
      ];
    };

    # The vzhost.nikopol baremetal segment — bare-br /25 (Incus dnsmasq + `.nikopol`
    # zone + the vzhost.nikopol host-record), the static /30 link to the corp Mac,
    # ip_forward and the forwarded-MSS clamp — is now provided uniformly by the
    # shared modules/nixos/baremetal-segment.nix, keyed off
    # catalog.netplan.baremetal.nikopol (bioskop gets the same, minus the /30).
    # Nothing baremetal-specific remains here.
  };
}
