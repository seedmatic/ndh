# A metalspace's private nix cache: attic in a cache container on its NixOS guest, through the one
# Incus container module (docs/private-binary-cache-spec.adoc, _One private cache per metalspace_).
#
# Every secret is generated inside the container, on its persistent disk, and never leaves it: the
# server secret at first start, the cache's signing key by attic when the cache is created (spec,
# _Secrets_). The NixOS guest only provides the disk: `tank/nerd/attic`, under its quota, split into
# three directories that reach the container as three disk devices.
#
# attic listens directly on the container's fabric address on :8080 (no TLS in the lab, the operator, 2026-10-30),
# and the container admits only the fabrics and the tailnet: the NixOS guest forwards a LAN packet routed at the
# fabric, so listening on the fabric alone does not keep the LAN out. nginx is gone: tokens are pulled via Incus.
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  cfg = config.ndh.atticCache;
  ndhPrefix = import ./systemd/ndh-prefix.nix { inherit lib; };
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
  chunksDir = "/var/lib/private/atticd/chunks";
  dbDir = "/var/lib/private/atticd/db";
  secretsDir = "/var/lib/private/atticd/secrets";
  # Shared with the guest: where attic-cache-ensure writes the cache's public for the guest to publish.
  sharedDir = "/var/lib/attic-shared";
  envFile = "${secretsDir}/server.env";
  # The served tokens: ciphertext only, rewritten at each mint, so no persistent device; a delivery starts it empty and
  # the timer's first tick (Persistent) fills it.
  tokensDir = "/var/lib/private/atticd/tokens";
  loopback = "127.0.0.1:8080";
  metalspace = if cfg.metalspace != null then cfg.metalspace else lib.removePrefix "attic." cfg.fqdn;
  # The guest's half of keys-reconcile's attic-cache-key class: on the ndh trampoline and logger, as host-key-generate.
  publish = ndh.store.installBinScript "attic-publish" (
    pkgs.replaceVars ./attic-cache.d/publish.sh (
      lib.mapAttrs (_: lib.escapeShellArg) {
        machine = config.networking.hostName;
        cache = metalspace;
        keyNameRegex = ndh.context.catalog.privateCaches.keyNamePattern metalspace;
        sharedPublic = "${paths.hostShared}/cache-key.public";
        base = "/var/lib/ndh";
        owner = "0";
        inherit (paths) publishDir;
        hostKey = config.ndh.hostKey.servedKeyFile;
      }
      // {
        inherit (ndh.context) nixBashTrampoline;
      }
    )
  );

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

    # /var/lib/private is 0700 root:root: only root traverses it. nginx is gone, so nothing else
    # needs to traverse it; the secrets, state, chunks and db stay 0700 behind it.
    systemd.tmpfiles.rules = [
      "d /var/lib/private 0700 root root - -"
      "d ${stateDir} 0711 atticd atticd - -"
    ];
    systemd.network.networks."10-fabric" = {
      matchConfig.Name = "eth0";
      address = [ cfg.address ];
      gateway = [ cfg.gateway ];
      networkConfig.LinkLocalAddressing = "no";
    };
    # The NixOS guest forwards a LAN packet routed at the fabric with its source kept (measured on
    # the probe, 2026-10-16), so the container itself admits only the fabrics and the tailnet.
    networking.firewall.extraInputRules = ''
      ip saddr { ${lib.concatStringsSep ", " cfg.allowedSources} } tcp dport 8080 accept
    '';

    services.atticd = {
      enable = true;
      package = config.ndh.atticPkgs.server;
      environmentFile = envFile;
      settings = {
        listen = "0.0.0.0:8080";
        database.url = "sqlite://${dbDir}/server.db?mode=rwc";
        storage = {
          type = "local";
          path = chunksDir;
        };
        api-endpoint = "http://${cfg.fqdn}:8080/";
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

    # DynamicUser (nixpkgs' atticd module) allocates atticd's uid at runtime; the parent directory
    # /var/lib/attic is declared as StateDirectory so systemd creates and chowns it to the dynamic
    # user. The chunks and db live on separate, shifted disks mounted under it by Incus.
    systemd.services.atticd.serviceConfig.StateDirectory = lib.mkForce "atticd";
    systemd.services.atticd.serviceConfig.StateDirectoryMode = "0700";
    systemd.services.atticd.serviceConfig.Environment = "RUST_LOG=info";

    systemd.services.${ndhPrefix.mkNdhUnitName "attic-server-secret"} = {
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

    # The tokens, minted here for every target and pulled by each machine (F6): weekly, valid twice that, so a missed
    # tick is harmless and two fail closed. `systemctl start attic-token-mint` is the « mint now » that follows a
    # rotation of the token-signing secret.
    systemd.services.${ndhPrefix.mkNdhUnitName "attic-token-mint"} = {
      description = "Mint the private cache's tokens for every machine, sealed to each access point";
      requires = [ "${ndhPrefix.mkNdhUnitName "attic-cache-ensure"}.service" ];
      after = [ "${ndhPrefix.mkNdhUnitName "attic-cache-ensure"}.service" ];
      # atticd-atticadm as attic-cache-ensure takes it: the atticd module's wrapper, which loads atticd's own config
      # and secret.
      path = [ "/run/current-system/sw" ];
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "CACHE_FQDN=${cfg.fqdn}"
          "METALSPACE=${metalspace}"
          "CACHE_NAME=${cfg.cacheName}"
          # Quoted: systemd cuts an unquoted value at its first space, and the mint got `--validity 14` (2026-10-30).
          "\"VALIDITY=${cfg.tokens.validity}\""
          # A file, one target per line: Environment= keeps a `\\n` as two characters, never a line break.
          "TARGETS_FILE=${
            pkgs.writeText "attic-token-targets" (
              lib.concatMapStrings (t: "${t.machine} ${t.metalspace} ${t.dir} ${t.publicKey}\n") cfg.tokenTargets
            )
          }"
        ];
        ExecStart = "${
          script "attic-token-mint" [
            pkgs.age
            pkgs.ssh-to-age
            pkgs.coreutils
            pkgs.findutils
          ] ./attic-cache.d/token-mint.sh
        }/bin/attic-token-mint ${tokensDir}";
      };
    };
    systemd.timers.${ndhPrefix.mkNdhUnitName "attic-token-mint"} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.tokens.period;
        OnActiveSec = "1min";
        Persistent = true;
      };
    };
    # A mint at every start of the container (a cold start included), and at every switch that changes who gets a
    # token (a seat's new host key): a oneshot that stays active, restarted when the targets change, starting the
    # mint. Not RemainAfterExit on the mint itself: its timer would then never run it again.
    systemd.services.${ndhPrefix.mkNdhUnitName "attic-token-mint-on-change"} = {
      description = "Mint now: at start, and whenever the token targets change";
      wantedBy = [ "multi-user.target" ];
      requires = [ "${ndhPrefix.mkNdhUnitName "attic-cache-ensure"}.service" ];
      after = [ "${ndhPrefix.mkNdhUnitName "attic-cache-ensure"}.service" ];
      restartTriggers = [ (builtins.toJSON cfg.tokenTargets) ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.systemd}/bin/systemctl start --no-block ${ndhPrefix.mkNdhUnitName "attic-token-mint"}.service";
      };
    };

    systemd.services.${ndhPrefix.mkNdhUnitName "attic-cache-ensure"} = {
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
                pkgs.curl
                pkgs.gnugrep
                pkgs.gnused
                pkgs.yq-go
                config.nix.package
              ] ./attic-cache.d/cache-ensure.sh
            }/bin/attic-cache-ensure"
            cfg.cacheName
            cfg.keyName
            cfg.retention
            "http://${loopback}"
            "${sharedDir}/cache-key.public"
          ]
          ++ cfg.upstreamKeyNames
        );
      };
    };
    # atticd's GC marks chunks as deleted but never removes their files from disk,
    # nor cleans up orphaned NARs or zero-holder chunks. This timer does that work.
    systemd.services.${ndhPrefix.mkNdhUnitName "attic-gc-cleanup"} = {
      description = "Clean up atticd's orphaned chunks and NARs (GC workaround)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${
          pkgs.writeShellApplication {
            name = "attic-gc-cleanup";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.sqlite
            ];
            text = builtins.readFile ./attic-cache.d/gc-cleanup.sh;
          }
        }/bin/attic-gc-cleanup";
      };
    };
    systemd.timers.${ndhPrefix.mkNdhUnitName "attic-gc-cleanup"} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
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
      description = "The cache's fabric name: nginx's server name, and attic's API endpoint.";
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
      default = "tank/nerd/attic/chunks";
      description = "ZFS dataset holding the container's state and secrets, and the directory it shares with the guest.";
    };

    quota = lib.mkOption {
      type = lib.types.str;
      default = "8G";
      description = "The dataset's ZFS quota, applied at every boot (operator, 2026-10-15).";
    };

    dbDataset = lib.mkOption {
      type = lib.types.str;
      default = "tank/nerd/attic/database";
      description = "ZFS dataset holding atticd's SQLite database, separate from the chunk storage.";
    };

    dbQuota = lib.mkOption {
      type = lib.types.str;
      default = "1G";
      description = "The database dataset's ZFS quota.";
    };

    retention = lib.mkOption {
      type = lib.types.str;
      default = "6 hours";
      description = "attic's retention period, server-wide and on the cache (operator, 2026-10-15).";
    };

    # The tokens rotate by themselves (the operator, 2026-10-22: never a rotation waiting on their hand): minted every
    # period, valid twice that; a machine fails loudly at three halves of it. attic cannot revoke, so `validity` bounds
    # a stolen token (🛡️, 2026-10-25).
    tokens = {
      period = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "weekly";
        description = "How often the cache mints its tokens (systemd OnCalendar).";
      };
      validity = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "14 days";
        description = "Each token's own validity (atticadm --validity): twice the period.";
      };
    };

    keyName = lib.mkOption {
      type = lib.types.str;
      # Named after the metalspace, as catalog/private-caches.nix accepts it (the probe, outside the catalog,
      # after its fabric name).
      default = "seedmatic-${
        if cfg.metalspace != null then cfg.metalspace else lib.removePrefix "attic." cfg.fqdn
      }-attic-1";
      defaultText = lib.literalExpression ''"seedmatic-''${metalspace}-attic-1"'';
      description = "The name of the cache's signing key, generated inside the cache container (attic would name it after the cache).";
    };

    cacheName = lib.mkOption {
      type = lib.types.str;
      default = "seedmatic";
      description = "The one private cache this attic serves.";
    };

    instanceName = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "attic-${
        if cfg.metalspace != null then cfg.metalspace else lib.removePrefix "attic." cfg.fqdn
      }";
      defaultText = lib.literalExpression ''"attic-''${metalspace}"'';
      description = ''
        The cache container's Incus instance name. Per metalspace, because the guests share one Incus cluster and an
        instance name is unique in its project across the cluster: two guests declaring `attic` would make one
        converge stop the other's. The fabric name (attic.<metalspace>) does not change with it.
      '';
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
      ++ lib.optional (metalspaceEntry.vzHostKind == "nix-managed") "${metalspaceEntry.vzHostAddress}/32"
      ++ lib.optional (
        metalspaceEntry.vzHostKind == "foreign" && (metalspaceEntry.vmGuestAddress or null) != null
      ) "${metalspaceEntry.vmGuestAddress}/32";
      defaultText = lib.literalExpression "the guest's netGateway, and the vz-host's /30 end when it is nix-managed";
      description = ''
        Sources the cache container accepts on :80: the access point's machines as they arrive,
        never the LAN, the cluster nodes or the other fabric instances. Through the tunnel the
        tailnet ACL is the only gate that tells machines apart.
      '';
    };

    upstreamKeyNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # The upstream caches' key names, from the catalog: never the fleet's build keys, which sign every path this
      # cache is there to hold.
      default = map (key: lib.head (lib.splitString ":" key)) (
        lib.concatMap (cache: lib.optional (cache ? publicKey) cache.publicKey) (
          lib.attrValues (builtins.removeAttrs ndh.context.catalog.caches [ "cachix" ])
        )
      );
      defaultText = lib.literalExpression ''[ "cache.nixos.org-1" "flox-cache-public-1" ]'';
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
              description = "Its access point's operator-seat host key, PUBLIC (`ssh-ed25519 AAAA…`), its current slot.";
            };
            dir = lib.mkOption {
              type = lib.types.str;
              description = "Where its tokens are served: a hash of the machine and its public, naming no machine.";
            };
          };
        }
      );
      default = import ../.common.d/attic-tokens.d/targets.nix {
        inherit lib netplan;
        inherit (config.ndh.keysYaml) keys;
      };
      defaultText = lib.literalExpression "modules/.common.d/attic-tokens.d/targets.nix";
      description = "The machines this cache mints tokens for, each with its access point's current public key.";
    };
  };

  config = lib.mkIf cfg.enable {
    # A token is sealed only to a verified public: never to a pending slot's, which keys-reconcile has not yet checked.
    assertions = [
      {
        assertion =
          let
            pending = lib.concatMap (
              entry:
              let
                slots = entry.slots or { };
              in
              map (n: "${entry.type or "ssh-ed25519"} ${slots.${n}.public or ""}") (
                lib.filter (n: (slots.${n}.state or "") == "pending") (lib.attrNames slots)
              )
            ) (lib.attrValues config.ndh.keysYaml.keys);
          in
          lib.all (t: !(lib.elem t.publicKey pending)) cfg.tokenTargets;
        message = "ndh.atticCache.tokenTargets: a token would be sealed to a PENDING slot's public, not yet verified by keys-reconcile";
      }
    ];
    ndh.incusNixosContainers.instances.${cfg.instanceName} = {
      inherit (cfg) target;
      # atticd and nginx face the fabric: a compromise must not be the NixOS guest's root.
      privileged = true;
      rollback = false;
      modules = [ guest ];
      # The trampoline's bringup profile, so the container's scripts can move onto the trampoline (batch 2): a bare
      # container imports none of ndh's common modules, and the strict trampoline refuses where the profile is
      # missing. Set host side at each delivery, never from the container's activation: unprivileged, its root
      # cannot write in the host-owned /nix bind, and the link failed there silently (🎛️, 2026-10-22).
      profiles.${config.ndh.bringupRuntime.profileDir} = config.ndh.bringupRuntime.runtimePackage;
      # The state, secrets and shared directory, all in one dataset: atticd migrates its DB forward on start, so a rollback
      # must bring the data back with the system (🛡️'s condition, the operator's ZFS-snapshot form, 2026-10-22).
      stateDatasets = [
        cfg.dataset
        cfg.dbDataset
      ];
      # attic-cache-ensure is the one that proves the cache private and its key well named.
      health.units = [
        "atticd.service"
        "${ndhPrefix.mkNdhUnitName "attic-server-secret"}.service"
        "${ndhPrefix.mkNdhUnitName "attic-cache-ensure"}.service"
      ];
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

        attic-chunks = {
          type = "disk";
          source = "${paths.hostChunksRoot}";
          path = chunksDir;
          shift = "true";
        };
        attic-db = {
          type = "disk";
          source = "${paths.hostDbRoot}";
          path = dbDir;
          shift = "true";
        };
        attic-secrets = {
          type = "disk";
          source = "${paths.hostRoot}/secrets";
          path = secretsDir;
        };
        attic-shared = {
          type = "disk";
          source = paths.hostShared;
          path = sharedDir;
        };
      };
    };

    # The cache's public, written by attic-cache-ensure on the device this guest shares, is signed here with the key
    # this guest serves and published for the seat (keys-reconcile, class attic-cache-key). At every activation, and
    # whenever the container rewrites it: the path is a hint, the activation the gate, so a missed trigger waits one
    # switch at most. Never fatal: nothing reads the publication until keys-reconcile collects it.
    system.activationScripts.ndhAtticPublish = {
      deps = [ "specialfs" ];
      supportsDryActivation = false;
      text = ''
        if ! ${pkgs.bash}/bin/bash ${publish}/bin/attic-publish; then
          echo "[attic-publish] FAILED to publish ${cfg.cacheName}'s public key; the next activation retries" >&2
        fi
      '';
    };
    systemd.paths.${ndhPrefix.mkNdhUnitName "attic-publish"} = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = "${paths.hostShared}/cache-key.public";
    };
    systemd.services.${ndhPrefix.mkNdhUnitName "attic-publish"} = {
      description = "Publish the cache container's public key, signed by this guest";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash ${publish}/bin/attic-publish";
      };
    };

    systemd.services.${ndhPrefix.mkNdhUnitName "attic-dataset"} = {
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
          || zfs create -p ${lib.escapeShellArg cfg.dataset}
        # Force the mountpoint on every activation: a dataset created by an earlier version (or by hand)
        # may carry a stale mountpoint, which would leave its source path absent and block convergence.
        zfs set mountpoint=${paths.hostChunksRoot} ${lib.escapeShellArg cfg.dataset}
        zfs set quota=${lib.escapeShellArg cfg.quota} ${lib.escapeShellArg cfg.dataset}
        zfs list -H -o name ${lib.escapeShellArg cfg.dbDataset} >/dev/null 2>&1 \
          || zfs create -p ${lib.escapeShellArg cfg.dbDataset}
        zfs set mountpoint=${paths.hostDbRoot} ${lib.escapeShellArg cfg.dbDataset}
        zfs set quota=${lib.escapeShellArg cfg.dbQuota} ${lib.escapeShellArg cfg.dbDataset}
        # On disk the cache's database and NARs belong to a uid of the container's range (systemd 260
        # maps atticd's StateDirectory): closed here, nothing of this NixOS guest walks into them.
        chmod 0700 ${paths.hostRoot} ${paths.hostDbRoot} ${paths.hostChunksRoot}
        install -d -m 0700 ${paths.hostRoot}/state ${paths.hostRoot}/secrets
        install -d -m 0755 ${paths.hostShared}
        install -d -m 0700 ${paths.hostDbRoot}
        # The container is privileged (identity mapping), so a host uid is the container uid.
        # atticd is a DynamicUser whose uid is 65312 in the container; chown the dataset roots to
        # that uid so atticd can read/write its chunks, db, state, secrets and shared dir.
        chown -R 65312:65312 ${paths.hostRoot} ${paths.hostChunksRoot} ${paths.hostDbRoot}
      '';
    };
  };
}
