{
  self,
  lib,
  pkgs,
  config,
  catalog,
  ...
}:
let
  networkCatalog = catalog.networks or { };
  cfg = config.services.crossHostBuilders;
  hostProfile = config.profile.host;
  hostName = hostProfile.hostName;
  # Avoid forcing an unset option value: only use hostAlias if attribute exists and is non-empty
  hostAlias =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostName;
  hostForcesRemoteBuilds = hostProfile.forceRemoteBuilds;
  userRemoteBuilders = hostProfile.remoteBuilders;
  builderCatalog = hostProfile.builderCatalog;
  # Exclude macOS builders that are themselves running inside a VM; they should offload elsewhere.
  builderCatalogFiltered = lib.filter (
    entry: !(entry.platform == "darwin" && entry.form == "vm")
  ) builderCatalog;
  catalogRemoteBuilders = map (entry: entry.builder) (
    lib.filter (entry: entry.builder != null) builderCatalogFiltered
  );
  userName = config.profile.user.name;
  userHome = config.profile.user.home;

  # Builder key paths (placed in /etc/nix for builders)
  builderKeyDir = "/etc/nix";
  builderKeyPath = "${builderKeyDir}/builder_ed25519";
  # Place SSH control sockets in a shared temp dir (nixbld users lack homedirs)
  controlMasterDir = "/var/tmp/nix-ssh-control";
  controlMasterPath = "${controlMasterDir}/ssh-builder-%r@%h:%p";

  # Align builder key provisioning with linux-builder module: pull from keys.yaml
  keysJson = pkgs.runCommand "keys.json" { buildInputs = [ pkgs.yq-go ]; } ''
    yq -o=json '.' ${../home-manager/ssh.d/keys.yaml} > $out
  '';
  keys = builtins.fromJSON (builtins.readFile keysJson);
  builderProfile = config.profile.name;
  builderPrivKey = keys.profiles.${builderProfile}.linux-builder.private;
  builderPubKey = keys.profiles.${builderProfile}.linux-builder.public;
  builderPrivStore = pkgs.writeText "builder_ed25519" builderPrivKey;
  builderPubStore = pkgs.writeText "builder_ed25519.pub" builderPubKey;

  builderKeyInstall = pkgs.runCommand "install-builder-key.sh" { } ''
    cp ${
      pkgs.replaceVars ./distributed-builds.d/install-builder-key.sh {
        inherit
          builderKeyDir
          builderPrivStore
          builderPubStore
          builderKeyPath
          ;
        activationLogger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/activation-logger.sh config;
      }
    } "$out"
    chmod +x "$out"
  '';

  # Prefer host-provided builder definitions (already feature-enriched)
  remoteBuilders = if userRemoteBuilders != [ ] then userRemoteBuilders else catalogRemoteBuilders;

  # Restrict requested networks to the known catalog and default to lan only
  resolveNetworks =
    nets:
    let
      requested = if nets != [ ] then nets else [ "lan" ];
    in
    lib.filter (net: builtins.hasAttr net networkCatalog) (lib.unique requested);

  networkDomain =
    net:
    let
      info = networkCatalog.${net};
    in
    if info ? domain then info.domain else "";

  # Sort builders so LAN-capable hosts are consulted first
  hasLan =
    builder: lib.elem "lan" (resolveNetworks (if builder ? networks then builder.networks else [ ]));
  remoteBuildersLanFirst = lib.sort (a: b: hasLan a && !(hasLan b)) remoteBuilders;

  # Expand each builder across its declared networks (LAN first) and weight LAN higher
  sanitizeForBuildMachines =
    builder:
    let
      nets = lib.sort (a: b: a == "lan" && b != "lan") (
        resolveNetworks (if builder ? networks then builder.networks else [ ])
      );
      baseSpeed = builder.speedFactor or 1;
      speedFor = net: baseSpeed * (if net == "lan" then 100 else 10);
      makeEntry =
        net:
        (lib.removeAttrs builder [
          "networks"
          "speedFactor"
        ])
        // {
          hostName = "${builder.hostName}-builder-via-${net}";
          speedFactor = speedFor net;
        };
    in
    map makeEntry nets;

  buildMachines = lib.concatMap sanitizeForBuildMachines remoteBuildersLanFirst;

in
{
  # Only apply the configuration on Darwin systems when enabled and builders are defined
  config =
    lib.mkIf (cfg.enable && pkgs.stdenv.isDarwin && hostForcesRemoteBuilds && remoteBuilders != [ ])
      {
        # Enable distributed builds
        nix.distributedBuilds = true;

        # Override build machines completely - don't let other modules add to it
        nix.buildMachines = lib.mkForce buildMachines;

        # Force remote-only builds and let builders use caches directly
        nix.settings = {
          builders-use-substitutes = true; # allow builders to pull from caches
          fallback = false; # fail rather than silently build locally
        }
        // (lib.optionalAttrs hostForcesRemoteBuilds {
          max-jobs = lib.mkForce 0; # never build locally when delegating builds
        });

        # Generate SSH host stanzas per builder and per advertised network
        # Pattern: <builderHostName>-builder-via-<network>
        environment.etc."ssh/ssh_config.d/60-builders.conf".text =
          let
            renderBuilder =
              builder:
              let
                builderHost = builder.hostName;
                targetHost = builder.sshHostName or builderHost;
                port = builtins.toString (builder.port or 22);
                nets = resolveNetworks (if builder ? networks then builder.networks else [ ]);
                hostForNet = net: "${targetHost}${networkDomain net}";
                connectTimeout = net: if net == "tailnet" then 30 else 10;
                renderNet = net: ''
                  Host ${builderHost}-builder-via-${net}
                    HostName ${hostForNet net}
                    Port ${port}
                    User builder
                    IdentityFile ${builderKeyPath}
                    IdentitiesOnly yes
                    StrictHostKeyChecking no
                    UserKnownHostsFile /dev/null
                    LogLevel QUIET
                    ConnectTimeout ${toString (connectTimeout net)}
                    ServerAliveInterval 30
                    ServerAliveCountMax 3
                    ControlMaster auto
                    ControlPath ${controlMasterPath}
                    ControlPersist 10m
                    Compression yes
                    TCPKeepAlive yes
                '';
              in
              lib.concatMapStrings renderNet nets;
          in
          lib.concatMapStrings renderBuilder remoteBuildersLanFirst;

        # Ensure ControlPath directory exists; use sticky bit to avoid cross-user clobbering
        system.activationScripts.builderControlPath = lib.mkAfter ''
          mkdir -p ${controlMasterDir}
          chmod 1777 ${controlMasterDir}
        '';

        # Ensure builder key is installed with proper permissions in /etc/nix (etc fragment)
        system.activationScripts.etc.text = lib.mkAfter ''
          ${builderKeyInstall}
        '';

        # Ensure the primary user (home-manager user) can read builder key via nixbld
        users.groups.nixbld.members = lib.mkAfter [ config.profile.user.name ];
      };
}
