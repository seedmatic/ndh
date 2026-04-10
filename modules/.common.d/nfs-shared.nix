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

  exportOptionsDefault = {
    darwin = "rw,async,no_subtree_check,no_root_squash";
    nixos = "rw,async,insecure,no_subtree_check,no_root_squash";
  };
  clientScopesDefault = {
    darwin = [
      {
        clients = "127.0.0.1/8";
        options = "mapall=0:0";
      }
      {
        clients = "192.168.1.0/24";
        options = "mapall=0:0";
      }
      {
        clients = "100.64.0.0/10";
        options = "mapall=0:0";
      }
      {
        clients = "10.80.16.0/24";
        options = "mapall=0:0"; # socket_vmnet shared network (vmhost0)
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
