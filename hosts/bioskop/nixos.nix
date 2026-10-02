{ ... }:
{
  config = {
    # Cachix watch-store token for auto-push of locally-built paths to
    # our nxmatic.cachix.org cache. Token path traced back to the repo's
    # .secrets file (SOPS-encrypted).
    services.nxmaticCachixWatchStore.sopsEncryptedTokenFile = ../../.secrets;

    # Cache signing (private deploy + trusted-public-keys + /etc/nix/*.pub)
    # is wired fleet-wide in modules/.common.d/nix-signing.nix — nothing
    # host-specific here.

    # Vector observability agent forwards build events to Darwin aggregator
    bringupObserve = {
      # Forward to Darwin host Vector aggregator via VM network gateway
      # VM NAT makes the macOS host accessible at 192.168.5.2
      upstreamEndpoint = "http://192.168.5.2:9001";
    };

    # sshfs mounts of the Darwin-side git store (replaces the old NFS /net automount).
    # Root executes the mount but authenticates as nxmatic — the operator who owns the
    # trees — via the CA-signed rdp-host key; remote files map back to uid/gid 501:30001.
    # bioskop now names the split the way nikopol does — object stores on one volume, coexisting
    # checkouts on the other — so this block is its twin, and the layout divergence is gone. The
    # old single /private/var/lib/git export is NOT kept: it carried 44 other orgs beside the
    # seedmatic closure, and nothing on the NixOS side ever consumed it.
    services.sshfsMounts = {
      enable = true;
      remoteHost = "bioskop.local";
      remoteUser = "nxmatic";
      identityFile = "/var/lib/ndh/ssh-keys/rdp-host";
      mounts = [
        {
          remotePath = "/Volumes/git-worktree-store";
          localPath = "/net/bioskop.local/Volumes/git-worktree-store";
        }
        {
          remotePath = "/Volumes/git-bare-store";
          localPath = "/net/bioskop.local/Volumes/git-bare-store";
        }
      ];
    };
  };
}
