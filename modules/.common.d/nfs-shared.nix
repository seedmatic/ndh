rec {
  # Common NFS defaults reused by Darwin and NixOS modules
  exportsDefault = {
    darwin = [
      "/private"
      "/private/var/lib/git"
      "/Users"
    ];

    nixos = [
      "/var/lib/git"
      "/home"
      "/var/tmp"
    ];
  };

  # Use soft/timeo/retrans to avoid system hangs on network errors
  # WARNING: Do not mount /net or any autofs path with ZFS datasets or overlays!
  # inet forces IPv4 only (no IPv6)
  mountOptionsDefault = "vers=3,proto=tcp,soft,timeo=5,retrans=2,actimeo=5,rsize=65536,wsize=65536,inet";

  # Squash remote root to nxmatic (uid 501) and tag the write with the
  # `nfs-remote` group (gid 30001, provisioned by
  # modules/{darwin,nixos}/nfs-remote-identity.nix). The dedicated gid
  # makes "this file came from a remote NFS write" visible in `ls -l`
  # and lets the operator membership flow through without sudo.
  #
  # NFS carries raw numeric ids on the wire, so the values must agree
  # numerically across every NFS host in the mesh — they do because the
  # nfs-remote group is pinned to gid 30001 by the shared module, and
  # uid 501 is the operator's id on every node.
  exportOptionsDefault = {
    darwin = "rw,async,no_subtree_check,maproot=501:30001";
    nixos = "rw,async,insecure,no_subtree_check,root_squash,anonuid=501,anongid=30001";
  };
  clientScopesDefault = {
    darwin = [
      {
        clients = "127.0.0.1/8";
        options = exportOptionsDefault.darwin;
      }
      {
        clients = "192.168.1.0/24";
        options = exportOptionsDefault.darwin;
      }
      {
        clients = "100.64.0.0/10";
        options = exportOptionsDefault.darwin;
      }
      {
        clients = "10.80.16.0/24";
        options = exportOptionsDefault.darwin; # socket_vmnet shared network (vmhost0)
      }
    ];

    nixos = [
      {
        clients = "127.0.0.1/8";
        options = exportOptionsDefault.nixos;
      }
      {
        clients = "192.168.1.0/24";
        options = exportOptionsDefault.nixos;
      }
      {
        clients = "100.64.0.0/10";
        options = exportOptionsDefault.nixos;
      }
      {
        clients = "10.80.16.0/24";
        options = exportOptionsDefault.nixos; # socket_vmnet shared network (vmhost0)
      }
    ];
  };

  timeoutsDefault = {
    mountTimeout = 5;
    mountQuickTimeout = 1;
    initialDownDelay = 8;
    nextDownDelay = 15;
    graceTime = 45;
    leaseTime = 60;
    nfsdThreads = 8;
    nfsdVers3 = true;
    nfsdVers4 = true;
  };
}
