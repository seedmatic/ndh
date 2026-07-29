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
      enable = true;
      # Forward to Darwin host Vector aggregator via VM network gateway
      # VM NAT makes the macOS host accessible at 192.168.5.2
      upstreamEndpoint = "http://192.168.5.2:9001";
    };

    # sshfs mounts of the Darwin-side git store (replaces the old NFS /net automount).
    # Root executes the mount but authenticates as nxmatic — the operator who owns the
    # trees — via the CA-signed rdp-host key; remote files map back to uid/gid 501:30001.
    # bioskop keeps its git trees under /private/var/lib/git.
    services.sshfsMounts = {
      enable = true;
      remoteHost = "bioskop.local";
      remoteUser = "nxmatic";
      identityFile = "/var/lib/ndh/ssh-keys/rdp-host";
      mounts = [
        {
          remotePath = "/private/var/lib/git";
          localPath = "/net/bioskop.local/private/var/lib/git";
        }
      ];
    };
  };
}
