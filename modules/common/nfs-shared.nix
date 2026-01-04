{
  # Common NFS defaults reused by Darwin and NixOS modules
  exportsDefault = [
    "/private"
    "/private/var/lib/git"
    "/nix/store"
    "/Users"
  ];

  mountOptionsDefault = "vers=3,proto=tcp,soft,timeo=60,retrans=2,actimeo=5,rsize=65536,wsize=65536";

  exportOptionsDefault = "rw,async,no_subtree_check,no_root_squash";
  clientScopesDefault = [
    {
      clients = "192.168.1.0/24";
      options = "rw,async,no_subtree_check,no_root_squash";
    }
    {
      clients = "100.64.0.0/10";
      options = "ro,sync,no_subtree_check,no_root_squash";
    }
  ];

  timeoutsDefault = {
    mountTimeout = 15;
    mountQuickTimeout = 5;
    initialDownDelay = 8;
    nextDownDelay = 15;
    graceTime = 45;
    leaseTime = 60;
    nfsdThreads = 8;
    nfsdVers3 = true;
    nfsdVers4 = true;
  };
}
