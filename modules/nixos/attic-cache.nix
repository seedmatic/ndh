# A metalspace's private nix cache: attic in a cache container on its NixOS guest, through the one
# Incus container module (docs/private-binary-cache-spec.adoc, _One private cache per metalspace_).
#
# Every secret is generated inside the container, on its persistent disk, and never leaves it: the
# server secret at first start, the cache's signing key by attic when the cache is created, the TLS
# key with a CSR the operator seat signs under mammoth-skate tls (spec, _Secrets_). The NixOS guest
# only provides the disk: `tank/nerd/attic`, under its quota, split into three directories that
# reach the container as three disk devices.
#
# attic listens on loopback; nginx serves it in TLS on the container's fabric address only, and the
# container admits only the fabrics and the tailnet: the NixOS guest forwards a LAN packet routed at
# the fabric, so listening on the fabric alone does not keep the LAN out.
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  cfg = config.ndh.atticCache;
  netplan = ndh.context.catalog.netplan;
  metalspaceEntry =
    if cfg.metalspace != null then
      netplan.baremetal.${cfg.metalspace}
    else
      throw "ndh.atticCache: outside the catalog (metalspace = null), state fqdn, gateway and allowedSources";
  paths = import ./attic-cache.d/paths.nix;
  fabricIp = lib.head (lib.splitString "/" cfg.address);
  # Container-side paths of the three directories of the dataset.
  stateDir = "/var/lib/private/atticd";
  secretsDir = "/var/lib/attic-secrets";
  tlsDir = "/var/lib/attic-tls";
  envFile = "${secretsDir}/server.env";
  loopback = "127.0.0.1:8080";

  script =
    name: runtimeInputs: file:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = builtins.readFile file;
    };

  guest = {
    networking.useDHCP = false;
    # networkd without systemd-resolved, which a container's host resolv.conf refuses; the cache
    # container resolves nothing.
    systemd.network.enable = true;
    services.resolved.enable = false;
    # Unprivileged, the container sees its store as `nobody`'s, and logrotate refuses a configuration
    # not owned by root. Its logs are the journal's, and /var/log starts empty at each delivery.
    services.logrotate.enable = false;
    systemd.network.networks."10-fabric" = {
      matchConfig.Name = "eth0";
      address = [ cfg.address ];
      gateway = [ cfg.gateway ];
      networkConfig.LinkLocalAddressing = "no";
    };
    # The NixOS guest forwards a LAN packet routed at the fabric with its source kept (measured on
    # the probe, 2026-10-16), so the container itself admits only the fabrics and the tailnet.
    networking.firewall.extraInputRules = ''
      ip saddr { ${lib.concatStringsSep ", " cfg.allowedSources} } tcp dport 443 accept
    '';

    services.atticd = {
      enable = true;
      package = config.ndh.atticPkgs.server;
      environmentFile = envFile;
      settings = {
        listen = loopback;
        api-endpoint = "https://${cfg.fqdn}/";
        garbage-collection = {
          interval = "15 minutes";
          default-retention-period = cfg.retention;
        };
        # attic has no default; the values of its own template.
        chunking = {
          nar-size-threshold = 65536;
          min-size = 16384;
          avg-size = 65536;
          max-size = 262144;
        };
      };
    };

    systemd.services.attic-server-secret = {
      description = "atticd's server secret, generated once in the cache container";
      requiredBy = [ "atticd.service" ];
      before = [ "atticd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${
          script "attic-server-secret" [
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.openssl
          ] ./attic-cache.d/server-secret.sh
        }/bin/attic-server-secret ${envFile}";
      };
    };

    systemd.services.attic-tls-key = {
      description = "The cache container's TLS key and its CSR";
      requiredBy = [ "nginx.service" ];
      before = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${
          script "attic-tls-key" [
            pkgs.coreutils
            pkgs.openssl
          ] ./attic-cache.d/tls-key.sh
        }/bin/attic-tls-key ${tlsDir} ${cfg.fqdn} nginx";
      };
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts.${cfg.fqdn} = {
        onlySSL = true;
        listen = [
          {
            addr = fabricIp;
            port = 443;
            ssl = true;
          }
        ];
        sslCertificate = "${tlsDir}/cert.pem";
        sslCertificateKey = "${tlsDir}/key.pem";
        locations."/" = {
          proxyPass = "http://${loopback}";
          extraConfig = ''
            client_max_body_size 0;
            proxy_request_buffering off;
          '';
        };
      };
    };
    systemd.services.nginx = {
      # Until the operator seat installs the signed leaf, nothing serves: attic stays on loopback.
      unitConfig.ConditionPathExists = "${tlsDir}/cert.pem";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
    };
    # The operator seat writes a new leaf on the NixOS guest (attic-leaf-sign); the container takes it
    # by itself: attic-tls-key checks it certifies the held key, then nginx serves it.
    systemd.paths.attic-tls-leaf = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = "${tlsDir}/cert.pem";
    };
    systemd.services.attic-tls-leaf = {
      description = "Take a new TLS leaf: check it against the held key, then serve it";
      serviceConfig.Type = "oneshot";
      script = "systemctl restart attic-tls-key.service nginx.service";
    };

    systemd.services.attic-cache-ensure = {
      description = "The private cache ${cfg.cacheName}, created and configured";
      wantedBy = [ "multi-user.target" ];
      requires = [ "atticd.service" ];
      after = [ "atticd.service" ];
      path = [
        config.ndh.atticPkgs.client
        "/run/current-system/sw"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 5;
        ExecStart = lib.escapeShellArgs (
          [
            "${
              script "attic-cache-ensure" [
                pkgs.coreutils
                pkgs.gnugrep
              ] ./attic-cache.d/cache-ensure.sh
            }/bin/attic-cache-ensure"
            cfg.cacheName
            cfg.retention
            "http://${loopback}"
          ]
          ++ cfg.upstreamKeyNames
        );
      };
    };
  };
in
{
  options.ndh.atticCache = {
    enable = lib.mkEnableOption "this metalspace's private nix cache, in a cache container";

    target = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "Incus member of this metalspace; `null` for a standalone Incus (see `ndh.incusNixosContainers`).";
    };

    metalspace = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "bioskop";
      description = ''
        The metalspace whose catalog entry (`netplan.baremetal.<name>`) gives the cache its fabric
        name, its gateway and the sources it admits. `null` outside the catalog (the probe): then
        those three are stated.
      '';
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = metalspaceEntry.atticFqdn;
      defaultText = lib.literalExpression "netplan.baremetal.\${metalspace}.atticFqdn";
      example = "attic.bioskop";
      description = "The cache's fabric name: the TLS leaf's only SAN, and attic's API endpoint.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "${metalspaceEntry.atticAddress}/${lib.last (lib.splitString "/" metalspaceEntry.netCidr)}";
      defaultText = lib.literalExpression "\"\${netplan.baremetal.\${metalspace}.atticAddress}/<netCidr's prefix>\"";
      example = "172.16.0.120/21";
      description = "The container's static address on fabric-br, with the fabric's prefix.";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      default = metalspaceEntry.netGateway;
      defaultText = lib.literalExpression "netplan.baremetal.\${metalspace}.netGateway";
      description = "fabric-br's address on this NixOS guest: the way to the other metalspace.";
    };

    dataset = lib.mkOption {
      type = lib.types.str;
      default = "tank/nerd/attic";
      description = "ZFS dataset holding the container's state, secrets and TLS key.";
    };

    quota = lib.mkOption {
      type = lib.types.str;
      default = "8G";
      description = "The dataset's ZFS quota, applied at every boot (operator, 2026-10-15).";
    };

    retention = lib.mkOption {
      type = lib.types.str;
      default = "6 hours";
      description = "attic's retention period, server-wide and on the cache (operator, 2026-10-15).";
    };

    cacheName = lib.mkOption {
      type = lib.types.str;
      default = "seedmatic";
      description = "The one private cache this attic serves.";
    };

    allowedSources = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      # Measured 2026-10-16: the NixOS guests SNAT what the tunnel forwards into the fabric (tailscale
      # NoSNAT=false), so every machine reached through the tailnet — the darwin host nikopol for its
      # own cache included — arrives as the guest's fabric-br address. A nix-managed vz-host (the
      # darwin host bioskop) reaches its fabric over the /30, as itself; a foreign one (the corporate
      # bare-metal) reads no cache, so its address stays out.
      default = [
        "${metalspaceEntry.netGateway}/32"
      ]
      ++ lib.optional (metalspaceEntry.vzHostKind == "nix-managed") "${metalspaceEntry.vzHostAddress}/32";
      defaultText = lib.literalExpression "the guest's netGateway, and the vz-host's /30 end when it is nix-managed";
      description = ''
        Sources the cache container accepts on :443: the access point's machines as they arrive,
        never the LAN, the cluster nodes or the other fabric instances. Through the tunnel the
        tailnet ACL is the only gate that tells machines apart.
      '';
    };

    upstreamKeyNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "cache.nixos.org-1" ];
      description = "Key names whose signatures make a path skipped at upload (attic's upstream filter).";
    };

    tokenTargets = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            machine = lib.mkOption { type = lib.types.str; };
            metalspace = lib.mkOption { type = lib.types.str; };
            publicKey = lib.mkOption {
              type = lib.types.str;
              description = "Its access point's operator-seat host key, PUBLIC (`ssh-ed25519 AAAA…`).";
            };
          };
        }
      );
      # Every metalspace's two machines — its darwin host and its NixOS guest — that share one access
      # point, whose age recipient is ssh-to-age of the operator seat's host key (roles x keys, S3b).
      # An access point with no host-<seat> key recorded yet is left out: its machines wait for it.
      default = lib.concatLists (
        lib.mapAttrsToList (
          host: bm:
          let
            slots = (config.ndh.keysYaml.keys."host-${host}" or { }).slots or { };
            newest = lib.last (lib.sort lib.lessThan (lib.attrNames slots));
            key = "${config.ndh.keysYaml.keys."host-${host}".type or "ssh-ed25519"} ${slots.${newest}.public}";
          in
          lib.optionals (slots != { }) (
            map
              (machine: {
                inherit machine;
                metalspace = host;
                publicKey = key;
              })
              [
                host
                bm.nixosHostname
              ]
          )
        ) (netplan.baremetal or { })
      );
      defaultText = lib.literalExpression "each metalspace's darwin host and NixOS guest, with its host-<seat> public key";
      description = "The machines attic-token-issue issues for, each with its access point's public key.";
    };
  };

  config = lib.mkIf cfg.enable {
    ndh.incusNixosContainers.instances.attic = {
      inherit (cfg) target;
      # atticd and nginx face the fabric: a compromise must not be the NixOS guest's root.
      privileged = false;
      modules = [ guest ];
      devices = {
        fabric = {
          type = "nic";
          nictype = "bridged";
          parent = "fabric-br";
          name = "eth0";
        };
        attic-state = {
          type = "disk";
          source = "${paths.hostRoot}/state";
          path = stateDir;
        };
        attic-secrets = {
          type = "disk";
          source = "${paths.hostRoot}/secrets";
          path = secretsDir;
        };
        attic-tls = {
          type = "disk";
          source = paths.hostTls;
          path = tlsDir;
        };
      };
    };

    # The operator (or the drop-box's channel) runs it on this NixOS guest: ciphertext only comes out.
    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "attic-token-issue";
        runtimeInputs = [
          config.virtualisation.incus.package
          pkgs.age
          pkgs.ssh-to-age
          pkgs.coreutils
          pkgs.findutils
        ];
        text = ''
          CACHE_FQDN=${lib.escapeShellArg cfg.fqdn}
          METALSPACE=${
            lib.escapeShellArg (
              if cfg.metalspace != null then cfg.metalspace else lib.removePrefix "attic." cfg.fqdn
            )
          }
          CACHE_NAME=${lib.escapeShellArg cfg.cacheName}
          PROJECT=${lib.escapeShellArg config.ndh.incusNixosContainers.project}
          INSTANCE=attic
          TARGETS=${
            lib.escapeShellArg (
              lib.concatMapStringsSep "\n" (t: "${t.machine} ${t.metalspace} ${t.publicKey}") cfg.tokenTargets
            )
          }
        ''
        + builtins.readFile ./attic-cache.d/token-issue.sh;
      })
    ];

    systemd.services.ndh-attic-dataset = {
      description = "The cache container's dataset, under its quota";
      wantedBy = [
        "multi-user.target"
        "incus-startup.service"
      ];
      before = [ "incus-startup.service" ];
      after = [ "zfs-mount.service" ];
      path = [ config.boot.zfs.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        zfs list -H -o name ${lib.escapeShellArg cfg.dataset} >/dev/null 2>&1 \
          || zfs create -p -o mountpoint=${paths.hostRoot} ${lib.escapeShellArg cfg.dataset}
        zfs set quota=${lib.escapeShellArg cfg.quota} ${lib.escapeShellArg cfg.dataset}
        # On disk the cache's database and NARs belong to a uid of the container's range (systemd 260
        # maps atticd's StateDirectory): closed here, nothing of this NixOS guest walks into them.
        chmod 0700 ${paths.hostRoot}
        install -d -m 0700 ${paths.hostRoot}/state ${paths.hostRoot}/secrets
        install -d -m 0755 ${paths.hostTls}
      '';
    };
  };
}
