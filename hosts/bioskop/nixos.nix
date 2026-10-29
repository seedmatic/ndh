{ ... }:
{
  config = {
    # Cache signing (private deploy + trusted-public-keys + /etc/nix/*.pub)
    # is wired fleet-wide in modules/.common.d/nix-signing.nix — nothing
    # host-specific here.

    # ★ This guest decrypts with an age identity the operator places at its keyFile, from their
    # secret manager. It imports nothing from its host: the /srv/host/sops.d share is bioskop's
    # ~/.config/sops, which holds the OPERATOR identity, and the import refreshed it at every boot.
    # A missing identity fails the age bootstrap unit and then sops-install-secrets (phase enforce);
    # nothing generates one.
    #
    # ⛔ No sshKeyPaths: the age identity is the one placed above, apart from the host key, so a host-key
    # rotation forces no re-key.
    ndh.sopsAgeKeyBootstrap = {
      defaultAgeKeyFile = "/var/lib/sops-nix/bioskop-nixos.age";
      nixosHostKeyImport.enable = false;
    };
    sops.age.sshKeyPaths = [ ];

    # This metalspace's private cache (docs/private-binary-cache-spec.adoc, per-metalspace): at a switch, its dataset
    # under its quota and its container (attic-<metalspace>), delivered by the guest's converge.
    ndh.atticCache = {
      enable = true;
      metalspace = "bioskop";
      target = "bioskop";
    };

    # Vector observability agent forwards build events to Darwin aggregator
    bringupObserve = {
      # Forward to Darwin host Vector aggregator via VM network gateway
      # VM NAT makes the macOS host accessible at 192.168.5.2
      upstreamEndpoint = "http://192.168.5.2:9001";
    };

    # sshfs mounts of the Darwin-side git store (replaces the old NFS /net automount).
    # Root executes the mount, read-only, as nxmatic — the operator who owns the trees — with the
    # guest's own host key, which the seat authorizes for sftp only; remote files map back to uid/gid 501:30001.
    # bioskop now names the split the way nikopol does — object stores on one volume, coexisting
    # checkouts on the other — so this block is its twin, and the layout divergence is gone. The
    # old single /private/var/lib/git export is NOT kept: it carried 44 other orgs beside the
    # seedmatic closure, and nothing on the NixOS side ever consumed it.
    services.sshfsMounts = {
      enable = true;
      remoteHost = "bioskop.local";
      remoteUser = "nxmatic";
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
