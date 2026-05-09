{
  self,
  lib,
  pkgs,
  config,
  catalog,
  inventory,
  ndh,
  ...
}:
let
  hostsInventory = inventory.hosts or { };
  qemu-pkgdb = self.packages.${pkgs.stdenv.hostPlatform.system}.qemu-pkgdb or pkgs.qemu;

  keys = builtins.fromJSON (
    builtins.readFile (
      ndh.store.runCommand "keys.json" { buildInputs = [ pkgs.yq-go ]; } ''
        yq -o=json '.' "${self}/modules/home-manager/ssh.d/keys.yaml" > $out
      ''
    )
  );

  # Public key trusted by the embedded linux-builder VM's authorized_keys
  # (read from flattened keys.yaml — top-level entries, no profile wrapper).
  linuxBuilderPubKey = keys.linux-builder.public;
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
  selected = if (!isBaremetalHost) then null else lib.head (linuxBuilderEntries ++ [ null ]);
  selectedLimaBuilder =
    if (!isBaremetalHost) then null else lib.head (limaBuilderEntries ++ [ null ]);
  requestedLinuxBuilderVmCpuCores =
    if selected != null then (selected.builder.vmCpuCores or 8) else 8;
  effectiveLinuxBuilderVmCpuCores = lib.min requestedLinuxBuilderVmCpuCores 8;
  # Lima nerd-nixos SSH port configured via lima.configGenerator.sshLocalPort (kept for reference)
  nerdNixosSshPort = config.lima.configGenerator.sshLocalPort or 0;
  nerdNixosBuilderEnabled = selectedLimaBuilder != null;
  # Key path shared by both embedded linux-builder (as fallback) and nerd-nixos builder
  builderKeyDir = "/etc/nix";
  builderKeyPath = "${builderKeyDir}/builder_ed25519";

in
{

  config = {
    warnings = lib.optional (selected != null && requestedLinuxBuilderVmCpuCores > 8) ''
      linux-builder requested ${toString requestedLinuxBuilderVmCpuCores} vCPUs, but qemu mach-virt supports up to 8 here.
      Clamping linux-builder VM vCPUs to 8.
    '';

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
          NDH_VECTOR_API_PORT  = "8686";
          NDH_VECTOR_ENDPOINT  = "http://127.0.0.1:9001";
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

    # nerd-nixos remote builder — connects directly over LAN
    nix.distributedBuilds = lib.mkIf nerdNixosBuilderEnabled true;

    nix.buildMachines = lib.optionals nerdNixosBuilderEnabled [
      {
        hostName = "bioskop-nixos.lan";
        systems = selectedLimaBuilder.builder.systems or [ "aarch64-linux" ];
        maxJobs = selectedLimaBuilder.builder.maxJobs or 8;
        protocol = "ssh-ng";
        sshUser = "nxmatic";
        sshKey = builderKeyPath;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
        speedFactor = 2;
      }
    ];

    # SSH config so the nix daemon can reach bioskop-nixos directly over LAN
    environment.etc."ssh/ssh_config.d/70-nerd-nixos-builder.conf" = lib.mkIf nerdNixosBuilderEnabled {
      text = ''
        Host bioskop-nixos.lan
          User nxmatic
          IdentityFile ${builderKeyPath}
          IdentitiesOnly yes
          AddKeysToAgent yes
          StrictHostKeyChecking no
          UserKnownHostsFile /dev/null
          LogLevel QUIET
          ServerAliveInterval 30
          ServerAliveCountMax 3
          ControlMaster auto
          ControlPath /var/tmp/nix-builder-ssh-control/%C
          ControlPersist 10m
          Compression yes
          TCPKeepAlive yes
      '';
    };

    # Deploy linux-builder private key for nix daemon (runs as root).
    # linux-builder declares `ssh-host` usage, so the enrichment pipeline
    # lands its private under systemKeysDir (root-owned, sudo-reachable).
    system.activationScripts.nerdNixosBuilderKey = lib.mkIf nerdNixosBuilderEnabled {
      text = ''
        user_key="${config.sshPaths.systemKeysDir}/linux-builder"
        dest="${builderKeyPath}"
        key_dir="${builderKeyDir}"

        install -d -m 0755 "$key_dir"
        install -d -m 0700 /var/tmp/nix-builder-ssh-control

        if [ -f "$user_key" ]; then
          install -m 0600 -o root -g wheel "$user_key" "$dest"
        else
          echo "nerd-nixos-builder: linux-builder key not yet deployed at $user_key (run ssh-keys activation first)" >&2
        fi
      '';
      deps = [ "setupActivationScript" ];
    };

    # Enable the shared nix-store identity deploy logic from
    # modules/.common.d/nix-store-identity.nix and run it during activation.
    # Platform detail: nix-darwin runs the script as a plain activation step;
    # on NixOS the same script is invoked from a systemd oneshot so it can
    # order after ssh-keys-enrichment.service.
    nixStoreIdentity.enable = true;

    system.activationScripts.nixStoreIdentity = {
      text = ''
        ${config.nixStoreIdentity.deployScript}/bin/nix-store-identity-deploy
      '';
      deps = [ "setupActivationScript" ];
    };
  };
}
