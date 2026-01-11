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
  builderCatalogFiltered = lib.filter (
    entry:
    let
      systems = entry.builder.systems or [ ];
      isDarwinSystem = lib.any (s: lib.hasInfix "darwin" s) systems;
      isVm = (entry.builder.form or "") == "vm";
    in
    !(isDarwinSystem && isVm)
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
  controlMasterDir = "/var/tmp/nix-builder-ssh-control";
  controlMasterPath = "${controlMasterDir}/%C";

  # Align builder key provisioning with linux-builder module: pull from keys.yaml
  keysJson = pkgs.runCommand "keys.json" { buildInputs = [ pkgs.yq-go ]; } ''
    yq -o=json '.' ${../home-manager/ssh.d/keys.yaml} > $out
  '';
  keys = builtins.fromJSON (builtins.readFile keysJson);
  builderProfile = config.profile.name;
  builderPrivKey = keys.profiles.${builderProfile}.linux-builder.private;
  builderPubKey = keys.profiles.${builderProfile}.linux-builder.public;
  # Ensure serialized keys always end with a newline to avoid parser quirks when installed by ssh
  builderPrivStore = pkgs.writeText "builder_ed25519" (builderPrivKey + "\n");
  builderPubStore = pkgs.writeText "builder_ed25519.pub" (builderPubKey + "\n");
  activationLogger = lib.attrByPath [
    "activation"
    "loggerScript"
  ] ../common/activation-logger.sh config;
  nixbldGroup = config.users.groups.nixbld.name or "nixbld";
  authorizedKeysDir = config.opensshPolicy.authorizedKeysDir;
  nixbldAuthorizedKeysPath = "${authorizedKeysDir}/${nixbldGroup}";

  builderKeyInstall = pkgs.runCommand "install-builder-key.sh" { } ''
    cp ${
      pkgs.replaceVars ./distributed-builds.d/install-builder-key.sh {
        inherit
          builderKeyDir
          builderPrivStore
          builderPubStore
          builderKeyPath
          ;
        activationLogger = activationLogger;
      }
    } "$out"
    chmod +x "$out"
  '';

  installAuthorizedKeys = pkgs.runCommand "install-builder-authorized-keys.sh" { } ''
    cp ${
      pkgs.replaceVars ./distributed-builds.d/install-authorized-keys.sh {
        authorizedKeysDir = authorizedKeysDir;
        groupName = nixbldGroup;
        builderPubKey = builderPubKey;
        activationLogger = activationLogger;
      }
    } "$out"
    chmod +x "$out"
  '';

  controlPathScript = pkgs.runCommand "ensure-builder-controlpath.sh" { } ''
    cp ${
      pkgs.replaceVars ./distributed-builds.d/ensure-control-path.sh {
        controlMasterDir = controlMasterDir;
        activationLogger = activationLogger;
      }
    } "$out"
    chmod +x "$out"
  '';

  postActivationScript = pkgs.runCommand "distributed-builds-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./distributed-builds.d/post-activation.sh {
        builderKeyInstall = builderKeyInstall;
        installAuthorizedKeys = installAuthorizedKeys;
        controlPathScript = controlPathScript;
        activationLogger = activationLogger;
      }
    } "$out"
    chmod +x "$out"
  '';

  # Prefer host-provided builder definitions (already feature-enriched), then dedupe
  remoteBuildersRaw = if userRemoteBuilders != [ ] then userRemoteBuilders else catalogRemoteBuilders;
  remoteBuilders = lib.unique remoteBuildersRaw;

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
      fallback = if net == "lan" then ".lan" else "";
    in
    if info ? domain && info.domain != null && info.domain != "" then info.domain else fallback;

  # Sort builders so LAN-capable hosts are consulted first
  hasLan =
    builder: lib.elem "lan" (resolveNetworks (if builder ? networks then builder.networks else [ ]));
  remoteBuildersLanFirst = lib.sort (a: b: hasLan a && !(hasLan b)) remoteBuilders;

  normalizeHost =
    name: if lib.hasSuffix "-darwin" name then lib.removeSuffix "-darwin" name else name;

  # Prefer explicit hostName (includes platform suffix like "-linux") over the
  # generic host value to avoid collapsing linux/darwin builders into the same
  # base alias (e.g., bioskop-linux-builder instead of bioskop-builder).
  baseHostName =
    builder:
    if builder ? hostName then
      normalizeHost builder.hostName
    else if builder ? sshHostName then
      normalizeHost builder.sshHostName
    else if builder ? host then
      normalizeHost builder.host
    else
      "";

  # Expand each builder across its declared networks (LAN first) and weight LAN higher
  sanitizeForBuildMachines =
    builder:
    let
      nets = lib.sort (a: b: a == "lan" && b != "lan") (
        resolveNetworks (if builder ? networks then builder.networks else [ ])
      );
      baseSpeed = builder.speedFactor or 1;
      speedFor = net: baseSpeed * (if net == "lan" then 100 else 10);
      # Keep builder.hostName (with platform suffix) for the BuildMachines entry so it
      # matches the SSH Host alias we render (e.g., bioskop-darwin-builder-via-lan).
      hostBase = if builder ? hostName then builder.hostName else baseHostName builder;
      makeEntry =
        net:
        # Strip non-buildMachines keys before emitting
        (lib.removeAttrs builder [
          "networks"
          "speedFactor"
          "form"
          "platformLabel"
          "hostKey"
          "host"
          "hostPort"
          "user"
          "sshHostName"
          "vm"
        ])
        // {
          hostName = "${hostBase}-builder-via-${net}";
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
            # Default builder port: 31022; specific builders (e.g., nixos/lima) will emit Port 22 overrides
            defaultPortForNet = net: 31022;

            commonBlock = ''
              Host *-builder-via-*
                User builder
                Port 31022
                IdentityFile ${builderKeyPath}
                IdentitiesOnly yes
                StrictHostKeyChecking no
                UserKnownHostsFile /dev/null
                LogLevel QUIET
                ServerAliveInterval 30
                ServerAliveCountMax 3
                ControlMaster auto
                ControlPath ${controlMasterPath}
                ControlPersist 10m
                Compression yes
                TCPKeepAlive yes
            '';

            platformWildcards = ''
              Host *-nixos-builder-*
                User ${config.profile.user.name}
            '';

            networkDefaults = ''
              Host *-via-lan
                ConnectTimeout 10
              Host *-via-tailnet
                ConnectTimeout 1
            '';

            renderSpecific =
              builder: net:
              let
                alias = "${builder.hostName}-builder-via-${net}";
                domain = networkDomain net;
                hostBase = baseHostName builder;
                hostForNet = if domain != "" then "${hostBase}${domain}" else hostBase;
                portValue =
                  let
                    resolvedPort = if builder ? hostPort then builder.hostPort else defaultPortForNet net;
                  in
                  if resolvedPort == defaultPortForNet net then null else resolvedPort;
              in
              ''
                Host ${alias}
                  HostName ${hostForNet}
              ''
              + (lib.optionalString (portValue != null) "  Port ${toString portValue}\n");

            renderedSpecific = lib.concatMap (
              builder:
              let
                nets = resolveNetworks (if builder ? networks then builder.networks else [ ]);
              in
              map (net: renderSpecific builder net) nets
            ) remoteBuildersLanFirst;
            uniqueRendered = lib.unique renderedSpecific;
          in
          lib.concatStrings (
            [
              commonBlock
              platformWildcards
              networkDefaults
            ]
            ++ uniqueRendered
          );

        # Install builder key and create ControlPath directory via post-activation script (runs as root)
        system.activationScripts.postActivation.text = lib.mkAfter ''
          ${postActivationScript}
        '';

        # Ensure sshd looks in our unified authorized keys directory and includes the nixbld file
        opensshPolicy.authorizedKeysFiles = lib.mkAfter [ nixbldAuthorizedKeysPath ];

        # Ensure the primary user (home-manager user) is in nixbld for key access
        users.groups.nixbld.members = lib.mkAfter [ config.profile.user.name ];
      };
}
