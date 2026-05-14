{
  self,
  lib,
  pkgs,
  config,
  catalog,
  inventory,
  ...
}:
let
  hostsInventory = inventory.hosts or { };
  qemu-pkgdb = self.packages.${pkgs.stdenv.hostPlatform.system}.qemu-pkgdb or pkgs.qemu;

  # Public key trusted by the embedded linux-builder VM's authorized_keys.
  # Sourced from the shared ndh.keysYaml surface
  # (modules/.common.d/keys-yaml.nix) so it travels through the same
  # one-derivation extraction used by the NixOS side — no duplicate
  # per-module yq/runCommand.
  linuxBuilderPubKey = config.ndh.keysYaml.keys.linux-builder.public;
  # Pull builder inventory entries for this host (if present)
  hostName = config.profile.host.hostName;
  cacheCatalog = catalog.caches;
  flakehubPublicKeys =
    if cacheCatalog.flakehub ? publicKeys then
      cacheCatalog.flakehub.publicKeys
    else
      [ cacheCatalog.flakehub.publicKey ];
  # Consider linux-builder only when running on baremetal hosts.
  # VM hosts (e.g. nikopol running as a Tart VZ VM) cannot run nested QEMU efficiently.
  isBaremetalHost =
    let
      form = config.profile.host.form or null;
    in
    form == null || form == "baremetal";
  inventoryEntries =
    if builtins.hasAttr hostName hostsInventory then hostsInventory.${hostName} else [ ];
  # Embedded linux-builder: nix-darwin managed QEMU VM (vm.manager == "nix-darwin")
  linuxBuilderEntries = lib.filter (
    entry:
    entry.builder != null
    && lib.elem "aarch64-linux" entry.builder.systems
    && (entry ? vm)
    && (entry.vm.manager or "") == "nix-darwin"
  ) inventoryEntries;
  # nerd-nixos Lima builder: Lima managed VM (vm.manager == "lima")
  limaBuilderEntries = lib.filter (
    entry:
    entry.builder != null
    && lib.elem "aarch64-linux" entry.builder.systems
    && (entry ? vm)
    && (entry.vm.manager or "") == "lima"
  ) inventoryEntries;
  # Local QEMU linux-builder enabled only on baremetal (bioskop) as a fallback
  # when nerd-nixos VM is not yet available. VM hosts (nikopol) cannot run
  # nested QEMU and bootstrap from pre-built configs from bioskop instead.
  selected = if (!isBaremetalHost) then null else lib.head (linuxBuilderEntries ++ [ null ]);
  selectedLimaBuilder = null; # Remote builders disabled
  requestedLinuxBuilderVmCpuCores =
    if selected != null then (selected.builder.vmCpuCores or 8) else 8;
  effectiveLinuxBuilderVmCpuCores = lib.min requestedLinuxBuilderVmCpuCores 8;
  # Lima nerd-nixos SSH port configured via lima.configGenerator.sshLocalPort (kept for reference)
  nerdNixosSshPort = config.lima.configGenerator.sshLocalPort or 0;
  nerdNixosBuilderEnabled = selectedLimaBuilder != null;
  # Key path shared by both embedded linux-builder (as fallback) and nerd-nixos builder
  builderKeyDir = "/etc/nix";
  builderKeyPath = "${builderKeyDir}/builder_ed25519";

  # Host-side directory the cache-trust compose script mirrors each
  # fleet signing key into (modules/.common.d/cache-trust.nix). 9p-shared
  # read-only into the linux-builder VM at guestCacheKeysDir so
  # aarch64-linux outputs are signed at build time rather than arriving
  # unsigned on bioskop and being rejected downstream.
  hostCacheKeysDir = "/var/lib/linux-builder/secrets";
  guestCacheKeysDir = "/srv/host/nix-keys";
  cachixNames = config.ndh.cacheTrust.cachixNames;

in
{

  config = {
    warnings = lib.optional (selected != null && requestedLinuxBuilderVmCpuCores > 8) ''
      linux-builder requested ${toString requestedLinuxBuilderVmCpuCores} vCPUs, but qemu mach-virt supports up to 8 here.
      Clamping linux-builder VM vCPUs to 8.
    '';

    # Tell the fleet cache-trust compose script to mirror each
    # <name>.key into hostCacheKeysDir, on top of /etc/nix/<name>.key.
    # The linux-builder VM mounts that directory read-only via 9p so
    # its nix-daemon can sign outputs with the same fleet keypairs
    # bioskop uses locally.
    ndh.cacheTrust.builderSecretsDir = lib.mkIf (selected != null) hostCacheKeysDir;

    nix.linux-builder = lib.mkIf (selected != null) {
      enable = true;
      ephemeral = true;
      workingDirectory = "/var/lib/linux-builder";
      maxJobs = selected.builder.maxJobs or 4;
      systems = selected.builder.systems or [ "aarch64-linux" ];
      protocol = selected.builder.protocol or "ssh-ng";
      speedFactor = selected.builder.speedFactor or 1;
      supportedFeatures =
        selected.builder.supportedFeatures or [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
      mandatoryFeatures = selected.builder.mandatoryFeatures or [ ];
      config = {
        virtualisation.darwin-builder.hostPort = selected.builder.hostPort or 31022;

        # 9p-share the host's mirrored cache-keys directory read-only into
        # the VM. securityModel = "none" leaves host file permissions
        # (0600 root) authoritative — the guest's nix-daemon runs as root
        # so it can read them; no uid/gid mapping needed. The guest
        # gets a fileSystems entry at target/ automatically via
        # qemu-vm.nix's sharedDirectories wiring.
        virtualisation.sharedDirectories.cacheKeys = {
          source = hostCacheKeysDir;
          target = guestCacheKeysDir;
          securityModel = "none";
        };

        # Increase Linux builder VM disk size to handle large disk image builds
        virtualisation.diskSize = lib.mkForce (selected.builder.diskSize or (150 * 1024)); # 150 GB for building 64GB+ images
        # Size the Linux builder VM itself (host for nested runInLinuxVM/QEMU image builds)
        # to reduce long install/copy phases during disk-image generation.
        virtualisation.cores = lib.mkForce effectiveLinuxBuilderVmCpuCores;
        virtualisation.memorySize = lib.mkForce (selected.builder.vmMemoryMiB or 16384);

        # Cap ZFS ARC so the linux-builder's own metadata cache doesn't crowd out pages
        # needed by the nested QEMU build VM. Formula: reserve half of vmMemoryMiB for
        # the QEMU process; give ARC the other half (min 2 GiB, max 12 GiB).
        # Example at 24 GiB: ARC max = 12 GiB, leaving 12 GiB for QEMU + OS overhead.
        boot.extraModprobeConfig =
          let
            vmMem = selected.builder.vmMemoryMiB or 16384;
            arcMaxMiB = lib.min 12288 (lib.max 2048 (vmMem / 2));
            arcMaxBytes = arcMaxMiB * 1024 * 1024;
            # Floor: keep at least 1 GiB in ARC even under memory pressure so
            # repeated store-path metadata lookups don't stall on cold-cache reads.
            arcMinBytes = 1073741824; # 1 GiB
          in
          ''
            options zfs zfs_arc_max=${toString arcMaxBytes}
            options zfs zfs_arc_min=${toString arcMinBytes}
          '';

        # Use the same binary caches and settings as the Darwin configuration
        nix.settings = {
          trusted-substituters = [
            cacheCatalog.flakehub.substituter # Determinate Systems FlakeHub cache
            cacheCatalog.nxmatic.substituter # nxmatic cache
          ];
          trusted-public-keys = [
          ]
          ++ flakehubPublicKeys
          ++ [
            cacheCatalog.nxmatic.publicKey # nxmatic key
          ];

          # Additional substituters from flox.conf
          extra-trusted-substituters = [
            cacheCatalog.flakehub.substituter
            cacheCatalog.nxmatic.substituter
          ];
          extra-trusted-public-keys = [
            "floxhub-1:0QOAlcobcEvq1mqEf4qAYCaWnTTOXpyoRv/PmqfSixM="
          ]
          ++ flakehubPublicKeys;

          # Connection and performance settings from flox.conf
          connect-timeout = lib.mkDefault 10;
          stalled-download-timeout = lib.mkDefault 30;

          # Buffer settings - increase download buffer to prevent buffer full warnings
          download-buffer-size = lib.mkDefault 268435456; # 256 MB (was 64 MB default)

          # Progress and logging settings
          log-lines = lib.mkDefault 50;

          # Storage management (use mkDefault to allow NixOS defaults to override)
          min-free = lib.mkDefault 128000000; # 128MB (from flox.conf)
          max-free = lib.mkDefault 1000000000; # 1GB (from flox.conf, but NixOS default 3GB will override)

          # Features
          # Enable content-addressed derivations inside the Linux builder VM to align with host and improve cache hit rate.
          experimental-features = [
            "nix-command"
            "flakes"
            "ca-derivations"
          ];
          accept-flake-config = true;
          always-allow-substitutes = true;

          # Sign aarch64-linux outputs with the fleet cachix keys the
          # host mirrors into guestCacheKeysDir (see sharedDirectories
          # above). Without this, paths built inside the builder would
          # arrive unsigned on bioskop and get rejected by downstream
          # hosts that only trust fleet-signed paths.
          secret-key-files = map (name: "${guestCacheKeysDir}/${name}.key") cachixNames;
        };

        # Configure SSH daemon to also check our profile keys file
        services.openssh.authorizedKeysFiles = [
          "/var/keys/%u_ed25519.pub" # Original nix-darwin key location
          "/etc/ssh/builder_keys.pub" # Our profile keys location in /etc
          "%h/.ssh/authorized_keys" # Standard user location
          "/etc/ssh/authorized_keys.d/%u" # System location
        ];

        # Default observability endpoint for embedded linux-builder guest.
        # Keep policy consistent with nested bringup VM diagnostics.
        services.monit = {
          enable = true;
          config = ''
            set daemon 10
            set logfile syslog

            set httpd port 2812 and
              use address 0.0.0.0
              allow localhost
              allow 10.0.2.2
          '';
        };

        # Vector agent: relays build telemetry from nested QEMU → macOS VZ aggregator.
        # 10.0.2.2 = macOS host (SLIRP gateway from linux-builder perspective).
        services.vector =
          let
            vectorConfigLib = import "${self}/modules/.common.d/vector-config.nix" { inherit lib; };
          in
          {
            enable = true;
            settings = vectorConfigLib.mkAgentConfig {
              apiPort = 8686;
              httpPort = 9001;
              upstreamEndpoint = "http://10.0.2.2:9001";
            };
          };

        environment.variables = {
          NDH_VECTOR_HTTP_PORT = "9001";
          NDH_VECTOR_API_PORT = "8686";
          NDH_VECTOR_ENDPOINT = "http://127.0.0.1:9001";
        };

        # Deploy the linux-builder SSH key to the VM using NixOS environment.etc with mode
        environment.etc = {
          "ssh/builder_keys.pub" = {
            text = lib.concatStrings [
              ''
                ssh-ed25519 ${linuxBuilderPubKey} ndh-linux-builder
              ''
            ];
            mode = "0644";
          };
        };

        # Allow builder to sudo without a password so no password is needed at all.
        users.users.builder = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
        };
        security.sudo.wheelNeedsPassword = lib.mkDefault false;
      };
    };

    # SSH keys are managed by the home-manager ssh-keys.nix module
    # Keys are deployed to canonical split runtime paths via sshPaths (system/public + per-user/private)

    # Distributed builds disabled: we now build locally on bioskop and copy
    # store paths to target hosts instead of using remote builders over LAN/tailscale.

    # SSH config for manual access to bioskop-nixos (works on LAN and tailscale/headscale)
    environment.etc."ssh/ssh_config.d/70-bioskop-nixos.conf" = {
      text = ''
        Host bioskop-nixos.lan bioskop-nixos
          User nxmatic
          StrictHostKeyChecking accept-new
          ServerAliveInterval 30
          ServerAliveCountMax 3
          ControlMaster auto
          ControlPath /var/tmp/ssh-control-%C
          ControlPersist 10m
          Compression yes
          TCPKeepAlive yes
      '';
    };

    # nix-store identity deploy wiring lives in
    # modules/darwin/nix-store-identity.nix (enable-by-default across
    # the fleet, activation ordered against ssh-keys-enrichment).
  };
}
