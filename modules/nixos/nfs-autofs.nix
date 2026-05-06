{
  config,
  lib,
  self,
  ...
}:
let
  shared = import "${self}/modules/.common.d/nfs-shared.nix";
  cfg = config.services.nfsAutofs;

  autoMasterLines = [
    "${cfg.mountPoint} ${cfg.map} ${cfg.mapOptions}"
  ];

  autoMasterText = lib.concatStringsSep "\n" autoMasterLines + "\n";

  nfsSettings = lib.optionalAttrs cfg.nfsConf.enable {
    client.mount_options_default = cfg.nfsConf.mountOptions;
    client.mount_timeout = cfg.nfsConf.mountTimeout;
    client.mount_quick_timeout = cfg.nfsConf.mountQuickTimeout;
    client.initialdowndelay = cfg.nfsConf.initialDownDelay;
    client.nextdowndelay = cfg.nfsConf.nextDownDelay;

    lockd.port = cfg.nfsConf.lockdPort;
    lockd.udp = cfg.nfsConf.lockdUdp;
    lockd.tcp = cfg.nfsConf.lockdTcp;
    lockd.send_using_mnt_transport = cfg.nfsConf.lockdUseMntTransport;

    mountd.port = cfg.nfsConf.mountdPort;

    nfsd.threads = cfg.nfsConf.nfsdThreads;
    nfsd.vers3 = cfg.nfsConf.nfsdVers3;
    nfsd.vers4 = cfg.nfsConf.nfsdVers4;
    nfsd."grace-time" = cfg.nfsConf.graceTime;
    nfsd."lease-time" = cfg.nfsConf.leaseTime;

    statd.port = cfg.nfsConf.statdPort;

    # Force IPv4 only for NFS (disable IPv6)
    server = {
      "nfsv3.tcp6" = false;
      "nfsv4.tcp6" = false;
    };
  };

  exportsText =
    let
      scopes =
        if cfg.server.clientScopes == [ ] then
          [
            {
              clients = "";
              options = cfg.server.exportOptions;
            }
          ]
        else
          cfg.server.clientScopes;
      scopeStrs = map (s: "${s.clients}(${s.options})") scopes;
    in
    lib.concatStringsSep "\n" (
      lib.map (path: "${path} " + lib.concatStringsSep " " scopeStrs) cfg.server.exports
    )
    + "\n";

in
{
  options.services.nfsAutofs = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable NFS client support with /net autofs map.";
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/net";
      description = "Mount point used for autofs host browsing.";
    };

    map = lib.mkOption {
      type = lib.types.str;
      default = "-hosts";
      description = "Autofs map used for on-demand host mounts.";
    };

    mapOptions = lib.mkOption {
      type = lib.types.str;
      default = "-soft,intr,nosuid";
      description = "Autofs options applied to the /net entry.";
    };

    timeout = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Autofs global timeout before idle mounts are dropped (seconds).";
    };

    server = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable NFS server with generated exports.";
      };
      exports = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = shared.exportsDefault.nixos;
        description = "Paths exported over NFS.";
      };
      exportOptions = lib.mkOption {
        type = lib.types.str;
        default = shared.exportOptionsDefault.nixos;
        description = "Export options applied to every shared path (fallback when clientScopes is empty).";
      };
      clientScopes = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              clients = lib.mkOption {
                type = lib.types.str;
                description = "Client CIDR or host spec.";
              };
              options = lib.mkOption {
                type = lib.types.str;
                description = "Export options for this client scope.";
              };
            };
          }
        );
        default = shared.clientScopesDefault.nixos;
        description = "Per-scope client/option pairs appended to each export.";
      };
    };

    nfsConf = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Generate /etc/nfs.conf with mobile-friendly defaults.";
      };
      mountOptions = lib.mkOption {
        type = lib.types.str;
        default = shared.mountOptionsDefault;
        description = "Default NFS mount options applied by mount.nfs.";
      };
      mountTimeout = lib.mkOption {
        type = lib.types.int;
        default = shared.timeoutsDefault.mountTimeout;
        description = "Initial mount timeout (seconds).";
      };
      mountQuickTimeout = lib.mkOption {
        type = lib.types.int;
        default = shared.timeoutsDefault.mountQuickTimeout;
        description = "Quick mount timeout for automounts (seconds).";
      };
      initialDownDelay = lib.mkOption {
        type = lib.types.int;
        default = shared.timeoutsDefault.initialDownDelay;
        description = "Delay before first not-responding notice (seconds).";
      };
      nextDownDelay = lib.mkOption {
        type = lib.types.int;
        default = shared.timeoutsDefault.nextDownDelay;
        description = "Delay between not-responding notices (seconds).";
      };
      lockdPort = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "Lockd port (0 lets the kernel choose).";
      };
      lockdUdp = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable UDP for lockd.";
      };
      lockdTcp = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable TCP for lockd.";
      };
      lockdUseMntTransport = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use the mount transport for lockd.";
      };
      mountdPort = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "mountd port (0 lets the kernel choose).";
      };
      nfsdThreads = lib.mkOption {
        type = lib.types.int;
        default = shared.timeoutsDefault.nfsdThreads;
        description = "nfsd thread count.";
      };
      nfsdVers3 = lib.mkOption {
        type = lib.types.bool;
        default = shared.timeoutsDefault.nfsdVers3;
        description = "Enable NFSv3.";
      };
      nfsdVers4 = lib.mkOption {
        type = lib.types.bool;
        default = shared.timeoutsDefault.nfsdVers4;
        description = "Enable NFSv4.";
      };
      graceTime = lib.mkOption {
        type = lib.types.int;
        default = shared.timeoutsDefault.graceTime;
        description = "Server grace period (seconds).";
      };
      leaseTime = lib.mkOption {
        type = lib.types.int;
        default = shared.timeoutsDefault.leaseTime;
        description = "Server lease time (seconds).";
      };
      statdPort = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "statd port (0 lets the kernel choose).";
      };
      extraText = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Extra nfs.conf lines to append verbatim (note: cannot be used with nfsSettings).";
      };
    };

  };

  config = lib.mkIf cfg.enable {
    boot.supportedFilesystems.nfs = true;
    boot.supportedFilesystems.nfs4 = true;

    services.autofs = {
      enable = true;
      timeout = cfg.timeout;
      autoMaster = autoMasterText;
    };

    # Feed upstream nfs.nix so it renders /etc/nfs.conf with our defaults
    # Note: extraConfig cannot be used together with settings in NixOS
    services.nfs.settings = lib.mkIf cfg.nfsConf.enable (lib.mkDefault nfsSettings);

    services.nfs.server = lib.mkIf cfg.server.enable {
      enable = true;
      nproc = cfg.nfsConf.nfsdThreads; # threads count
      mountdPort = lib.mkIf (cfg.nfsConf.mountdPort != 0) cfg.nfsConf.mountdPort;
      lockdPort = lib.mkIf (cfg.nfsConf.lockdPort != 0) cfg.nfsConf.lockdPort;
      statdPort = lib.mkIf (cfg.nfsConf.statdPort != 0) cfg.nfsConf.statdPort;
      exports = exportsText;
    };
  };
}
