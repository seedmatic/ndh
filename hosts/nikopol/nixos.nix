{
  config,
  lib,
  ndh,
  ...
}:
let
  bm = ndh.context.catalog.netplan.baremetal.nikopol;
in
{
  config = {
    profile.user.home = lib.mkForce "/home/${config.profile.user.name}";

    # ★ This guest decrypts with an age identity the operator places at its keyFile, from their
    # keyring; nothing on the guest generates one, and only the public half is a recipient
    # (.sops.yaml). It imports nothing from the vz host: that host is the corporate-managed
    # Mac, and what this guest used to fetch from it — over ssh or the /srv/host/sops.d share
    # — was the OPERATOR identity, which opens every sops file in ndh.
    #
    # ⛔ No sshKeyPaths: the age identity is the one placed above, apart from the host key, so a host-key
    # rotation forces no re-key.
    ndh.sopsAgeKeyBootstrap = {
      defaultAgeKeyFile = "/var/lib/sops-nix/nikopol-nixos.age";
      nixosHostKeyImport.enable = false;
    };
    sops.age.sshKeyPaths = [ ];

    # The store freeze is tried here first: bioskop carries the toolchain we work from, so a
    # failure on nikopol breaks nothing we depend on (docs/store-freeze-spec.adoc, the rollout).
    ndh.storeFreeze.enable = true;

    # This metalspace's private cache (docs/private-binary-cache-spec.adoc, per-metalspace): at a switch, its dataset
    # under its quota and its container (attic-<metalspace>), delivered by the guest's converge.
    ndh.atticCache = {
      enable = true;
      metalspace = "nikopol";
      target = "nikopol";
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
    # nikopol keeps its git trees on dedicated /Volumes stores.
    services.sshfsMounts = {
      enable = true;
      remoteHost = "nikopol.local";
      remoteUser = "nxmatic";
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

    # The vz host serves its LLM gateway agent on its loopback :4001 only; this guest publishes it on the fabric
    # gateway address for the two operator seats, which both arrive over the tailnet (measured 2026-10-21).
    ndh.loopbackForward.vzhost-4001 = {
      listen = {
        address = bm.netGateway;
        port = 4001;
      };
      target = {
        address = bm.vzHostAddress;
        user = bm.vzHostUser;
        hostKey = bm.vzHostKey;
        port = 4001;
      };
      from = bm.hostAddress;
      clients = [
        "100.76.71.8" # darwin.bioskop
        "100.89.203.77" # darwin.nikopol
      ];
    };

    # The vzhost.nikopol baremetal segment — fabric-br /25 (Incus dnsmasq + `.nikopol`
    # zone + the vzhost.nikopol host-record), the static /30 link to the corp Mac,
    # ip_forward and the forwarded-MSS clamp — is now provided uniformly by the
    # shared modules/nixos/baremetal-segment.nix, keyed off
    # catalog.netplan.baremetal.nikopol (bioskop gets the same, minus the /30).
    # Nothing baremetal-specific remains here.
  };
}
