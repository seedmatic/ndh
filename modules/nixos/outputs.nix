{
  self,
  nixpkgs,
  pkgsForLinux,
  ndhStoreApiLinux,
  ndhNixBashTrampolineLinux,
  ndhBootstrapRuntimePackageLinux,
  mkModulesFor,
  mkSpecialArgs,
  disko,
  sops-nix,
}:
let
  ndhNixBashTrampoline = ndhNixBashTrampolineLinux;

  mkNixosConfig =
    {
      hostProfile,
      profileModule,
      generationMode,
      zfsOverlays,
      catalog,
      inventory,
      vmProvider ? null,
      # Prebuilt production system store path baked into bringup image.
      # Set for bringup configs so zfs-nixos-install.service can use the
      # pre-downloaded closure instead of building from the flake at runtime.
      runtimeSystemPath ? null,
    }:
    let
      bringupModeInternal = generationMode == "bringup";
      effectiveVmProvider = if vmProvider != null then vmProvider else (hostProfile.vmProvider or "tart");
      zfsOverlaysModule =
        { ... }:
        {
          zfsOverlays.enable = zfsOverlays;
        };
      nixosTailscaleTagModule =
        { ... }:
        {
          tailscale.tags = [ "nixos" ];
        };
      preModules = [
        profileModule
        zfsOverlaysModule
        {
          ndh.vm.provider = effectiveVmProvider;
        }
      ]
      ++ (if bringupModeInternal then [ ] else [ nixosTailscaleTagModule ]);
      modules = mkModulesFor {
        inherit hostProfile preModules generationMode;
        system = "nixos";
      };
      specialArgs = mkSpecialArgs {
        inherit modules;
        system = "aarch64-linux";
        extraArgs = {
          ndh = {
            context = {
              inherit
                hostProfile
                generationMode
                catalog
                inventory
                ;
              vmProvider = effectiveVmProvider;
              nixBashTrampoline = ndhNixBashTrampoline;
              # Empty string when unset; zfs-nixos-install.nix asserts non-empty in bringup mode.
              runtimeSystemPath = if runtimeSystemPath != null then builtins.toString runtimeSystemPath else "";
            };
            store = ndhStoreApiLinux;
          };
        };
      };
      nixosSystem = nixpkgs.lib.nixosSystem {
        inherit modules specialArgs;
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
      };
    in
    nixosSystem;

  mkNixosOutputs =
    {
      hostProfile,
      profileModule,
      catalog,
      inventory,
      # When false, the bringup image omits the production runtime closure.
      # Use for base/template images (e.g. nerd-nixos) that carry no runtime deployment.
      includeRuntimeClosure ? true,
      # When true, the QEMU build VM pauses after nixos-install completes.
      # Remove /tmp/xchg/pause.lock from the debug shell to resume.
      # Set NDH_BRINGUP_PAUSE=true in the environment and pass --impure to nix build.
      pauseAfterInstall ? false,
      # When true, enable build observability (sampler + event emission).
      # Set NDH_BUILD_OBSERVE=true to enable.
      enableBuildObserve ? false,
      # Observability sample interval in seconds (shared across all layers).
      # Set NDH_BUILD_OBSERVE_INTERVAL=N to customize.
      buildObserveInterval ? 5,
    }:
    let
      mkImageModulesFor =
        {
          hp,
          generationMode,
        }:
        let
          hpBringupModeInternal = generationMode == "bringup";
          hpVmProvider = hp.vmProvider or "tart";
          zfsOverlaysModule =
            { ... }:
            {
              zfsOverlays.enable = false;
            };
          nixosTailscaleTagModule =
            { ... }:
            {
              tailscale.tags = [ "nixos" ];
            };
        in
        mkModulesFor {
          hostProfile = hp;
          inherit generationMode;
          system = "nixos";
          preModules = [
            profileModule
            zfsOverlaysModule
            {
              ndh.vm.provider = hpVmProvider;
            }
          ]
          ++ (if hpBringupModeInternal then [ ] else [ nixosTailscaleTagModule ]);
        };

      mkImageSpecialArgsFor =
        hp: generationMode: modules:
        mkSpecialArgs {
          inherit modules;
          system = "aarch64-linux";
          extraArgs = {
            ndh = {
              context = {
                hostProfile = hp;
                inherit
                  generationMode
                  catalog
                  inventory
                  ;
                vmProvider = hp.vmProvider or "tart";
                nixBashTrampoline = ndhNixBashTrampoline;
              };
              store = ndhStoreApiLinux;
            };
          };
        };

      bringupSystemdHostProfileBase = hostProfile // {
        nixosBootLoader = "systemd-boot";
        nixosBringupRootFs = "zfs";
      };

      runtimeSystemdHostProfile = hostProfile // {
        nixosBootLoader = "systemd-boot";
      };

      selectedVmProvider = hostProfile.vmProvider or "tart";

      # Full runtime systems (for cloud-init to fetch and activate)
      zfsRuntimeTart = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        generationMode = "full";
        hostProfile = runtimeSystemdHostProfile;
        zfsOverlays = true;
        vmProvider = "tart";
        runtimeSystemPath = null; # No nested reference
      };

      zfsRuntimeLima = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        generationMode = "full";
        hostProfile = runtimeSystemdHostProfile;
        zfsOverlays = true;
        vmProvider = "lima";
        runtimeSystemPath = null;
      };

      selectedRuntime = if selectedVmProvider == "tart" then zfsRuntimeTart else zfsRuntimeLima;
      fullSystemPath = selectedRuntime.config.system.build.toplevel;

      # Minimal bringup system — ZFS + network + cloud-init only.
      # Completely standalone, no host profile or modules imported.
      # Generate a deterministic hostId from hostname for ZFS.
      minimalHostId =
        let
          hash = builtins.hashString "sha256" hostProfile.hostName;
          # Take first 8 hex chars from hash for ZFS hostId
        in
        builtins.substring 0 8 hash;

      minimalBringupSystemBase = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
        specialArgs = { inherit self; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          ./bringup-minimal-system.nix
          {
            networking.hostId = minimalHostId;
            # networking.hostName is composed inside bringup-minimal-system.nix
            # as "${hostProfile.hostName}-nixos" so the bringup guest carries
            # the same composite identity the runtime uses (via lima-host.nix).
            system.stateVersion = "25.11";

            # Disko configuration - needed for zfs.nix to generate fileSystems
            disko.devices = diskoConfiguration.devices;

            # Pass full system path as a plain string (unsafeDiscardStringContext strips
            # the derivation edge so the runtime closure is NOT pulled into the bringup
            # image). Cloud-init userdata is seeded via nocloud xchg virtio-9p share and
            # bakes these values at eval time — no kernel params needed.
            _module.args.ndh = {
              context = {
                generationMode = "bringup";
                vmProvider = selectedVmProvider;
                nixBashTrampoline = ndhNixBashTrampoline;
                # hostProfile: consumed by .common.d/sops.nix (vmProvider fallback)
                # and profile.nix. Keep minimal.
                inherit hostProfile;
                # catalog: profile.nix reads catalog.user. Pass only the
                # user sub-tree to avoid pulling the full inventory.
                catalog = { inherit (catalog) user; };
                # inventory: ssh-keys-enrichment reads inventory.hosts for the
                # comma-separated host list that seeds authorized_principals.
                inherit inventory;
                # runtimeSystemPath: unsafeDiscardStringContext strips the derivation edge
                # so the full runtime system is NOT pulled into the bringup closure.
                runtimeSystemPath = builtins.unsafeDiscardStringContext (builtins.toString fullSystemPath);
                # Connect as the `nix-store` user: a system user provisioned
                # symmetrically on NixOS and Darwin via
                # modules/.common.d/nix-store-identity.nix. Its login shell
                # execs `nix-daemon --stdio`, and its cert (principal
                # `nix-store`) is matched by sshd.
                #
                # Use ssh-ng:// (not ssh://): the nix-store-shell exec's
                # nix-daemon --stdio, which speaks the new daemon protocol.
                # Legacy ssh:// expects to spawn shell commands (cat,
                # nix-store --export) and fails with "protocol mismatch"
                # against a daemon-speaking stdio endpoint.
                remoteStore = "ssh-ng://nix-store@${hostProfile.hostName}.local";
                bringupRuntimePackage = ndhBootstrapRuntimePackageLinux;
                # Must match the path the bootstrap trampoline reads in
                # modules/.common.d/shell.d/nix-bash-trampoline.sh (`ndh::bootstrap:profile:dir`)
                # and the module default in
                # modules/.common.d/io-nxmatic-nix-darwin-home-bringup-runtime.nix:151.
                bringupRuntimeProfilePath =
                  "/nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bringup-runtime";
              };
              store = ndhStoreApiLinux;
            };
          }
        ];
      };

      # Minimal system uses selected VM provider from host profile
      # No need for separate Lima/Tart variants since vmProvider is already set
      limaBringupSystemdZfs = minimalBringupSystemBase;
      tartBringupSystemdZfs = minimalBringupSystemBase;

      # Canonical raw build image size policy.
      # - `uncompressedDiskSizeGiB` is the baseline required without compression.
      # - A single compression factor is currently used.
      # - For zstd level 1, actual measured compressratio on NixOS store data is ~1.38x
      #   (factor = 1/1.38 ≈ 0.7246). The old 0.5 (2:1) assumption was too optimistic.
      # - Default uncompressedDiskSizeGiB=4 is calibrated to produce ~2.0G vdev disks
      #   (same ballpark as the old formula: unc=6 × factor=0.5). Tune per host via
      #   nixosDiskImageSizeGiB to match the actual uncompressed runtime closure size.
      # - Future per-filesystem factors may override rootFsCompressionFactor,
      #   but should default to zstdCompressionFactor.
      uncompressedDiskSizeGiB = hostProfile.nixosDiskImageSizeGiB or 4;
      selectedZstdCompressionLevel = hostProfile.nixosZstdCompressionLevel or 1;
      zstdCompressionFactor = if selectedZstdCompressionLevel == 1 then 0.7246 else 1.0;
      rootFsCompressionFactor = hostProfile.nixosRootFsCompressionFactor or zstdCompressionFactor;
      diskSizeGiB =
        let
          # Always round up, including decimal GiB inputs (e.g. 10.1 -> 11).
          scaledDiskSizeGiB = builtins.ceil (uncompressedDiskSizeGiB * rootFsCompressionFactor);
        in
        if scaledDiskSizeGiB < 1 then 1 else scaledDiskSizeGiB;
      diskSizeMiB = diskSizeGiB * (1024);
      diskSizeBytes = diskSizeMiB * (1024 * 1024);
      efiSystemPartitionSizeMiB = hostProfile.nixosEfiSystemPartitionSizeMiB or 512;
      diskImageVmMemSizeMiB = hostProfile.nixosDiskImageVmMemSizeMiB or 8192;
      # Nested QEMU runs under TCG (no KVM in linux-builder) — each vCPU is a
      # software-emulated host thread with lock contention. nixos-install is I/O-bound
      # (ZFS writes), not CPU-bound. 2 vCPUs reduces TCG overhead vs 6 while still
      # allowing nix-store and the install to interleave. Overridable per host.
      diskImageVmCpuCores = hostProfile.nixosDiskImageVmCpuCores or 4;
      zfsBringupPoolDiskSizeMiB = hostProfile.nixosZfsBringupPoolDiskSizeMiB or 12288;
      # ZFS vdev disk size for the bringup QEMU build VM.
      # Applies rootFsCompressionFactor so physical disk images reflect compressed
      # on-disk size (measured zstd-1 ratio: 1.38x → factor 0.7246).
      # raidz1 usable = 2 × zpoolVdevPartitionSizeMiB (3 disks, 1 parity).
      # Accounts for per-disk EFI/GPT overhead:
      # espStart=1 MiB + efiSystemPartitionSizeMiB + 1 MiB GPT backup = +2 beyond EFI.
      zpoolVdevDiskSizeMiB =
        hostProfile.nixosZpoolVdevDiskSizeMiB or (
          builtins.ceil (uncompressedDiskSizeGiB * rootFsCompressionFactor * 512.0)
          + efiSystemPartitionSizeMiB
          + 2
        );
      # Compute bringupZfsSystemPath after selectedBringupSystemdZfs is defined
      bringupZfsSystemPath = selectedBringupSystemdZfs.config.system.build.toplevel;
      # Output a JSON hint with all relevant info for post-build checks
      diskSizeHint = builtins.toJSON {
        systemPath = bringupZfsSystemPath;
        diskSizeBytes = diskSizeBytes;
        diskSizing = {
          uncompressedDiskSizeGiB = uncompressedDiskSizeGiB;
          zstdCompressionLevel = selectedZstdCompressionLevel;
          zstdCompressionFactor = zstdCompressionFactor;
          rootFsCompressionFactor = rootFsCompressionFactor;
          finalDiskSizeGiB = diskSizeGiB;
        };
        diskSizeMiB = {
          runtime = diskSizeMiB;
          zpoolVdevDisk = zpoolVdevDiskSizeMiB;
          zfsBringupPool = zfsBringupPoolDiskSizeMiB;
        };
        diskImageVmResources = {
          memSizeMiB = diskImageVmMemSizeMiB;
          cpuCores = diskImageVmCpuCores;
        };
        efiSystemPartitionSizeMiB = efiSystemPartitionSizeMiB;
        hint = {
          zfsBringup = "nix path-info -Sh ${bringupZfsSystemPath}";
        };
        note = "minimal bringup closure sizes should be less than diskSizeBytes; inspect boot-size-hint.yaml in image outputs to tune ESP size from measured single-generation usage";
      };
      mainName =
        if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
          hostProfile.hostAlias
        else
          hostProfile.hostName;

      zfsPoolDiskMap = import ./zfs-pool-disk-map.nix;

      mkDiskImageManifestAttrs =
        {
          attr,
          imageMode,
          bootLoader,
          diskSizeMiB,
          efiSystemPartitionSizeMiB,
          sourceOutPath,
          nixosConfiguration,
          primaryImagePath ? "boot.img",
          zpools ? [ ],
        }:
        {
          schemaVersion = 1;
          kind = "nixos-disk-image";
          inherit
            attr
            nixosConfiguration
            imageMode
            bootLoader
            sourceOutPath
            ;
          format = "raw-efi";
          imagePath = primaryImagePath;
          inherit
            diskSizeMiB
            efiSystemPartitionSizeMiB
            ;
          images = [ ];
          inherit zpools;
        };

      mkDiskImageWithManifest =
        {
          attr,
          imageMode,
          bootLoader,
          diskSizeMiB,
          efiSystemPartitionSizeMiB,
          nixosConfiguration,
          source,
          primaryImagePath ? "boot.img",
          extraImages ? [ ],
          zpools ? [ ],
        }:
        let
          manifestAttrsJson = builtins.toJSON (mkDiskImageManifestAttrs {
            inherit
              attr
              imageMode
              bootLoader
              diskSizeMiB
              efiSystemPartitionSizeMiB
              nixosConfiguration
              zpools
              ;
            sourceOutPath = source;
            inherit primaryImagePath;
          });
          manifestBaseYamlFile = ndhStoreApiLinux.runCommand "manifest-base-${attr}.yaml" {
            nativeBuildInputs = [ pkgsForLinux.yq-go ];
            passAsFile = [ "manifestAttrsJson" ];
            inherit manifestAttrsJson;
          } ''yq -p json -o yaml "$manifestAttrsJsonPath" > "$out"'';
          extraImagesSpecYamlFile = ndhStoreApiLinux.runCommand "manifest-extra-images-${attr}.yaml" {
            nativeBuildInputs = [ pkgsForLinux.yq-go ];
            passAsFile = [ "extraImagesJson" ];
            extraImagesJson = builtins.toJSON extraImages;
          } ''yq -p json -o yaml "$extraImagesJsonPath" > "$out"'';
          manifestAssemblyScript = pkgsForLinux.replaceVars ./mk-disk-image-with-manifest.sh {
            nixBashTrampoline = "${ndhNixBashTrampoline}";
            loggerTag = "nixos.outputs.mkDiskImageWithManifest.${attr}";
          };
        in
        ndhStoreApiLinux.runCommand "${attr}"
          {
            nativeBuildInputs = [ pkgsForLinux.yq-go ];
            NDH_PRIMARY_IMAGE_PATH = primaryImagePath;
            NDH_MANIFEST_BASE_YAML_FILE = manifestBaseYamlFile;
            NDH_EXTRA_IMAGES_SPEC_YAML_FILE = extraImagesSpecYamlFile;
            # Disable strict bootstrap profile check for minimal bringup images
            NDH_BOOTSTRAP_STRICT = "0";
          }
          ''
            set -euo pipefail

            ${pkgsForLinux.bash}/bin/bash ${manifestAssemblyScript} "$out" "${source}"
          '';

      mkBringupZfsDiskImages =
        {
          nixosSystem,
          name,
          hostLabel ? mainName,
          runtimeSystemPath ? null,
          pauseAfterInstall ? false,
          enableBuildObserve ? false,
          buildObserveInterval ? 5,
          cloudInitUserData ? null,
        }:
        import ./bringup-zfs-disk-image.nix {
          lib = nixpkgs.lib;
          pkgs = pkgsForLinux;
          config = nixosSystem.config;
          # Use the bringup configuration closure for the bootstrap stage.
          installSystemPath = nixosSystem.config.system.build.toplevel;
          # Include the production runtime closure so zfs-nixos-install can use
          # the prebuilt path without network access at first boot.
          inherit runtimeSystemPath;
          inherit pauseAfterInstall;
          inherit enableBuildObserve;
          inherit buildObserveInterval;
          inherit hostLabel;
          inherit cloudInitUserData;
          zpoolDiskSize = zpoolVdevDiskSizeMiB;
          memSize = diskImageVmMemSizeMiB;
          vmCpuCores = diskImageVmCpuCores;
          includeChannel = false;
          inherit name;
          # Pass pre-computed disko config to avoid a second evaluation of zfs-disko-config.nix.
          inherit diskoConfiguration;
        };

      # ZFS bringup image selected by vmProvider — Lima and Tart differ in guest-side units.
      selectedBringupSystemdZfs =
        if selectedVmProvider == "tart" then tartBringupSystemdZfs else limaBringupSystemdZfs;

      diskImageBringupZfsSystemdBootRaw = mkBringupZfsDiskImages {
        nixosSystem = selectedBringupSystemdZfs;
        name = "${mainName}-zfs-disk-images-raw";
        # No runtime system closure — minimal bringup only
        runtimeSystemPath = null;
        inherit pauseAfterInstall;
        inherit enableBuildObserve;
        inherit buildObserveInterval;
        # Pass cloud-init user-data for minimal bringup
        cloudInitUserData = selectedBringupSystemdZfs.config.system.build.cloudInitUserData or null;
      };

      diskImageBringupZfsSystemdBoot = mkDiskImageWithManifest {
        attr = "${mainName}-zfs-disk-images";
        nixosConfiguration = "${mainName}-bringup";
        imageMode = "bringup";
        bootLoader = "systemd-boot";
        diskSizeMiB = diskSizeMiB;
        efiSystemPartitionSizeMiB = efiSystemPartitionSizeMiB;
        source = diskImageBringupZfsSystemdBootRaw;
        # primaryImagePath defaults to "boot.img" — dedicated EFI boot disk
        # zpools is populated at runtime from boot-size-hint.yaml (zpool status inside QEMU)
      };

      # Per-host disko configuration with computed disk sizes.
      # Exposed as diskoConfigurations."${mainName}-nixos" in the flake.
      diskoConfiguration = import ./zfs-disko-config.nix {
        lib = nixpkgs.lib;
        inherit hostProfile;
        diskImageSize = "${toString zpoolVdevDiskSizeMiB}M";
        espSizeMiB = efiSystemPartitionSizeMiB;
        # espStart(1) + espSize + 1 MiB alignment gap — matches bringup-zfs-disk-image.nix.
        zfsStartMiB = 2 + efiSystemPartitionSizeMiB;
      };

    in
    {
      inherit diskSizeHint;
      inherit diskSizeGiB;
      inherit diskSizeMiB;
      inherit diskoConfiguration;
      nixosConfigurations = {
        # Minimal bringup installer VM (what gets installed onto ZFS disks as the bootstrap OS)
        "${mainName}-bringup" = minimalBringupSystemBase;
        # Full runtime systems (what cloud-init activates after first boot)
        "${mainName}-lima" = zfsRuntimeLima;
        "${mainName}-tart" = zfsRuntimeTart;
      };
      inherit
        diskImageBringupZfsSystemdBoot
        ;
    };
in
{
  inherit mkNixosConfig mkNixosOutputs;
}
