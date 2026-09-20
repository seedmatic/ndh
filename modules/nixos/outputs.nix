{
  self,
  worktreePath,
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
    }:
    let
      effectiveVmProvider = if vmProvider != null then vmProvider else (hostProfile.vmProvider or "tart");
      zfsOverlaysModule =
        { ... }:
        {
          zfsOverlays.enable = zfsOverlays;
        };
      preModules = [
        profileModule
        zfsOverlaysModule
        {
          ndh.vm.provider = effectiveVmProvider;
        }
      ];
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

  # The fleet-generic FULL generation: the placeholder host `nerd-nixos`, which
  # already exists as the shared bringup, evaluated in `full` mode instead of
  # minimal.  It is the missing half of that host — without it the runtime side
  # is only N per-host closures with no fleet-wide part to factor out, and every
  # node has to carry its whole 7.5 GiB runtime as a private EROFS layer.
  #
  # Built from the literal host definition, never from the caller's hostProfile
  # or profileModule: the point is that every host derives the byte-identical
  # closure, so its layer image dedups across the fleet the way the bringup
  # image already does.  `catalog` and `inventory` are fleet-wide data, so they
  # are the only inputs that may cross into it.
  fleetRuntimeHostProfile = (import ../../hosts/nerd-nixos).hostProfile;

  mkFleetRuntimeConfig =
    { catalog, inventory }:
    mkNixosConfig {
      hostProfile = fleetRuntimeHostProfile;
      profileModule =
        { lib, ... }:
        {
          imports = [
            (import ../../hosts/host-common.nix {
              hostProfile = fleetRuntimeHostProfile;
              darwinProfile = { };
            })
          ];
          # Pinned rather than left to default: the profile set decides what the
          # generic layer contains, so a host must not be able to widen it.
          config.profile.names = lib.mkForce [
            "system"
            "user"
          ];
        };
      generationMode = "full";
      zfsOverlays = true;
      vmProvider = "tart";
      inherit catalog inventory;
    };

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
          hpVmProvider = hp.vmProvider or "tart";
          zfsOverlaysModule =
            { ... }:
            {
              zfsOverlays.enable = false;
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
          ];
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

      # Full runtime system — the target the node hands itself over to on
      # first boot, packed as the stack's third layer.  Lima variant was
      # retired — both fleet hosts run Tart.
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
      };

      selectedRuntime = zfsRuntimeTart;
      fullSystemPath = selectedRuntime.config.system.build.toplevel;

      # The shared middle of the stack.  Same value for every host by
      # construction — see mkFleetRuntimeConfig.
      fleetRuntimeSystemPath =
        (mkFleetRuntimeConfig {
          inherit catalog inventory;
        }).config.system.build.toplevel;

      # Minimal bringup system — ZFS + network + SSH only.  This closure
      # is bit-identical for every host on the fleet (no hostProfile-derived
      # bake): hostName is the literal "nerd-nixos" and hostId is a
      # placeholder.  Per-host identity is injected at first boot by the
      # per-host Tart bootstrap installer via cloud-init userdata
      # (cidata ISO mechanism).  The disk image bundle around it is per-host,
      # because it packs the host's runtime layer — see
      # diskImageBringupZfsSystemdBootRaw.
      #
      # The bringup-minimal config receives a generic ndh.context
      # carrying only the catalog user and the inventory (the
      # latter for ssh-keys-enrichment's authorized_principals
      # seed, which is fleet-shared).  See
      # docs/bringup-image-unification.adoc for the design.
      minimalBringupSystemBase = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
        specialArgs = { inherit self worktreePath; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          ./bringup-minimal-system.nix
          {
            # Placeholder hostId.  Real value is set at first boot by
            # cloud-init writing /etc/hostid.  ZFS pool import survives
            # any hostId because zfs.nix sets boot.zfs.forceImportRoot.
            networking.hostId = "00000000";
            # networking.hostName comes from bringup-minimal-system.nix
            # (literal "nerd-nixos"); cloud-init's `hostname:` directive
            # overrides at first boot.
            system.stateVersion = "25.11";

            # Disko configuration - needed for zfs.nix to generate fileSystems
            disko.devices = diskoConfiguration.devices;

            _module.args.ndh = {
              context = {
                generationMode = "bringup";
                # vmProvider is fleet-uniform (Tart today; Lima legacy).
                # Picking the operator's chosen provider is fine since
                # the bringup config doesn't dispatch on it.
                vmProvider = selectedVmProvider;
                nixBashTrampoline = ndhNixBashTrampoline;
                # catalog: profile.nix reads catalog.user.  Pass only
                # the user sub-tree.  No host-scoped catalog material.
                catalog = { inherit (catalog) user; };
                # inventory: ssh-keys-enrichment reads inventory.hosts
                # for the comma-separated host list that seeds
                # authorized_principals.  Same on every host —
                # the fleet's allow-list of registered hosts.
                inherit inventory;
                bringupRuntimePackage = ndhBootstrapRuntimePackageLinux;
                # Must match the path the bootstrap trampoline reads in
                # modules/.common.d/shell.d/nix-bash-trampoline.sh
                # (`ndh::bootstrap:profile:dir`) and the module default
                # in modules/.common.d/io-seedmatic-ndh-bringup-runtime.nix.
                bringupRuntimeProfilePath = "/nix/var/nix/profiles/per-user/root/io-seedmatic-ndh-bringup-runtime";
              };
              store = ndhStoreApiLinux;
            };
          }
        ];
      };

      # The bringup config is identity-less; this alias is retained for
      # source-level clarity at the call sites.
      tartBringupSystemdZfs = minimalBringupSystemBase;

      # Canonical raw build image size policy.
      # - `uncompressedDiskSizeGiB` is the baseline required without compression.
      # - A single compression factor is currently used.
      # - For zstd level 1, actual measured compressratio on NixOS store data is ~1.38x
      #   (factor = 1/1.38 ≈ 0.7246). The old 0.5 (2:1) assumption was too optimistic.
      # - Default uncompressedDiskSizeGiB=8 comfortably holds the current minimal
      #   bringup closure (~2.4 GiB uncompressed, ~1.7 GiB after zstd-1) plus the
      #   full runtime toplevel the operator ships in via `nix copy` during
      #   remote activation, with headroom for ZFS metadata + dedup reference
      #   overhead. Tune per host via nixosDiskImageSizeGiB if the full runtime
      #   closure grows beyond the default.
      # - Future per-filesystem factors may override rootFsCompressionFactor,
      #   but should default to zstdCompressionFactor.
      uncompressedDiskSizeGiB = hostProfile.nixosDiskImageSizeGiB or 8;
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
          # Populated at build time from `zpool status --json` (a map), so the
          # unpopulated default matches that shape rather than being a list.
          zpools ? { },
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
          # Whole filesystem images built by their own derivation, symlinked
          # into the bundle as `<name>.img` (never blank-created or resized).
          prebuiltImages ? { },
          # Ordered description of the /nix/store layer stack, for the operator
          # reading a disk set.  Purely descriptive: nothing branches on it.
          storeLayers ? [ ],
          # Populated at build time from `zpool status --json` (a map), so the
          # unpopulated default matches that shape rather than being a list.
          zpools ? { },
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
          prebuiltImagesSpecYamlFile = ndhStoreApiLinux.runCommand "manifest-prebuilt-images-${attr}.yaml" {
            nativeBuildInputs = [ pkgsForLinux.yq-go ];
            passAsFile = [ "prebuiltImagesJson" ];
            prebuiltImagesJson = builtins.toJSON (
              nixpkgs.lib.mapAttrsToList (imageName: image: {
                name = imageName;
                path = "${image}";
              }) prebuiltImages
            );
          } ''yq -p json -o yaml "$prebuiltImagesJsonPath" > "$out"'';
          storeLayersSpecYamlFile = ndhStoreApiLinux.runCommand "manifest-store-layers-${attr}.yaml" {
            nativeBuildInputs = [ pkgsForLinux.yq-go ];
            passAsFile = [ "storeLayersJson" ];
            storeLayersJson = builtins.toJSON storeLayers;
          } ''yq -p json -o yaml "$storeLayersJsonPath" > "$out"'';
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
            NDH_PREBUILT_IMAGES_SPEC_YAML_FILE = prebuiltImagesSpecYamlFile;
            NDH_STORE_LAYERS_SPEC_YAML_FILE = storeLayersSpecYamlFile;
            # Disable strict bootstrap profile check for minimal bringup images
            NDH_BOOTSTRAP_STRICT = "0";
          }
          ''
            set -euo pipefail

            ${pkgsForLinux.bash}/bin/bash ${manifestAssemblyScript} "$out" "${source}"
          '';

      # Sizing/disko knobs default to the host-derived values, but the
      # fleet-wide bringup caller overrides them with literal constants
      # to keep the produced drv host-agnostic (any hostProfile bleed
      # would tag the same-bytes output with a different store path,
      # defeating cross-host dedup).
      mkBringupZfsDiskImages =
        {
          nixosSystem,
          name,
          hostLabel ? mainName,
          # Required: it is the stack's third layer and the toplevel the node
          # hands itself over to.  No default — a null would fail deeper, in
          # the layer's closureInfo.
          runtimeSystemPath,
          pauseAfterInstall ? false,
          enableBuildObserve ? false,
          buildObserveInterval ? 5,
          builderZpoolDiskSizeMiB ? zpoolVdevDiskSizeMiB,
          builderMemSizeMiB ? diskImageVmMemSizeMiB,
          builderVmCpuCores ? diskImageVmCpuCores,
          builderDiskoConfiguration ? diskoConfiguration,
        }:
        import ./bringup-zfs-disk-image.nix {
          lib = nixpkgs.lib;
          pkgs = pkgsForLinux;
          config = nixosSystem.config;
          nixBashTrampoline = "${ndhNixBashTrampoline}";
          # Use the bringup configuration closure for the bootstrap stage.
          installSystemPath = nixosSystem.config.system.build.toplevel;
          inherit runtimeSystemPath;
          # Not a per-call knob: the middle layer is the same for every host, so
          # it comes from the enclosing scope rather than from the caller.
          inherit fleetRuntimeSystemPath;
          inherit pauseAfterInstall;
          inherit enableBuildObserve;
          inherit buildObserveInterval;
          inherit hostLabel;
          zpoolDiskSize = builderZpoolDiskSizeMiB;
          memSize = builderMemSizeMiB;
          vmCpuCores = builderVmCpuCores;
          includeChannel = false;
          inherit name;
          # Pass pre-computed disko config to avoid a second evaluation of zfs-disko-config.nix.
          diskoConfiguration = builderDiskoConfiguration;
        };

      # ZFS bringup image (Tart-only fleet).
      selectedBringupSystemdZfs = tartBringupSystemdZfs;

      # Bringup image is identity-less (see minimalBringupSystemBase): the
      # bytes are bit-identical for every host on the fleet.  Use a fixed
      # host-agnostic derivation name ("nerd-bringup-…") so nix actually
      # dedups the build across hosts.  Every builder-side knob is overridden
      # with a fleet-wide constant to keep the drv host-agnostic; threading
      # `hostProfile`-derived values would tag two distinct store paths
      # despite identical output bytes (the `nixosDiskImageVm{CpuCores,
      # MemSizeMiB}` knobs legitimately differ per host because they
      # describe the darwin host's nested-QEMU capacity, not the image).
      # Size of each pool disk in the bringup image, shared by the disko layout
      # and the raw file the builder truncates — they must agree, or disko lays
      # out partitions for a disk larger than the file backing it.
      #
      # Sized for what the bringup install actually writes, which is now tiny:
      # the store left the pool for its own EROFS disk, so the pool only carries
      # the root dataset, the Nix database and the (initially empty) overlay
      # upper. Measured on the produced image: 22 MiB per tank disk, 9 MiB on
      # recover. 1540 MiB leaves a 1025 MiB ZFS partition (1540 - 1 GPT - 512
      # ESP - 1 alignment - 1 tail), i.e. ~45x headroom and far above ZFS's
      # 64 MiB per-vdev floor.
      #
      # Runtime capacity does NOT depend on this: the Tart activation grows each
      # disk to `vmDataDiskSizeGiB` before first boot and ZFS autoexpands, which
      # is what makes room for the runtime closure in the overlay upper.
      #
      # Why it is worth shrinking at all — NARs do not preserve sparseness, so
      # every MiB here is copied from the builder and pushed to the cache even
      # though the file is almost entirely zeros. It does not speed the build
      # itself (truncate is instant; only those 22 MiB are written).
      bringupZpoolDiskSizeMiB = 1540;

      bringupDiskoConfiguration = import ./zfs-disko-config.nix {
        lib = nixpkgs.lib;
        # Empty hostProfile — zfs-disko-config.nix only reads
        # `nixosZstdCompressionLevel` (defaults to 1).
        hostProfile = { };
        diskImageSize = "${toString bringupZpoolDiskSizeMiB}M";
        espSizeMiB = 512;
        zfsStartMiB = 2 + 512;
      };
      diskImageBringupZfsSystemdBootRaw = mkBringupZfsDiskImages {
        nixosSystem = selectedBringupSystemdZfs;
        name = "nerd-bringup-zfs-disk-images-raw";
        hostLabel = "nerd";
        # Packed as the stack's second layer, so the node mounts the runtime
        # closure instead of materializing it.  This is what makes the bundle
        # per-host, which the fleet-wide comment above was protecting against:
        # measured, 1608 of ~1660 paths are common to bioskop and nikopol (9.19
        # GiB) and only 54 are host-private (34 MiB), so the fix is a shared
        # base layer plus a per-host residue — not keeping the runtime out.
        runtimeSystemPath = fullSystemPath;
        inherit pauseAfterInstall;
        inherit enableBuildObserve;
        inherit buildObserveInterval;
        # Fleet-wide constants — see comment above.  The pool disk size is no
        # longer derived from the store's compressed size (the store moved to
        # its own EROFS disk); see bringupZpoolDiskSizeMiB for how it is sized
        # now.
        builderZpoolDiskSizeMiB = bringupZpoolDiskSizeMiB;
        builderMemSizeMiB = 8192;
        builderVmCpuCores = 4;
        builderDiskoConfiguration = bringupDiskoConfiguration;
      };

      diskImageBringupZfsSystemdBoot = mkDiskImageWithManifest {
        attr = "nerd-bringup-zfs-disk-images";
        nixosConfiguration = "nerd-bringup";
        imageMode = "bringup";
        bootLoader = "systemd-boot";
        diskSizeMiB = diskSizeMiB;
        efiSystemPartitionSizeMiB = efiSystemPartitionSizeMiB;
        source = diskImageBringupZfsSystemdBootRaw.diskImages;
        # The store layers are packed on the host, so they are not among the
        # disks the nested guest writes — each joins the bundle as its own image,
        # keyed by the `imageName` its layer declares.
        prebuiltImages = diskImageBringupZfsSystemdBootRaw.storeImages;
        storeLayers = diskImageBringupZfsSystemdBootRaw.storeLayersSpec;
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
        # Minimal bringup installer VM (what gets installed onto ZFS disks as the bootstrap OS).
        # The bringup config is identity-less: every host's `${mainName}-bringup`
        # evaluates to the same derivation. The fleet-wide `nerd-nixos` alias
        # is exposed once at the top level (see flake.nix nixosConfigurations).
        "${mainName}-bringup" = minimalBringupSystemBase;
        # Full runtime system. `${mainName}-tart` is the canonical provider-tagged
        # name; `${mainName}-nixos` is the host-named alias used for ergonomic
        # `nixos-rebuild switch --flake .#<host>-nixos`.
        "${mainName}-tart" = zfsRuntimeTart;
        "${mainName}-nixos" = zfsRuntimeTart;
      };
      inherit
        diskImageBringupZfsSystemdBoot
        ;
      # Full runtime system closure for the selected vmProvider. Exposed so
      # the Darwin-side materializer can pull it into its own closure (one
      # `nix build` stages both the bringup image and the full system the
      # operator will activate remotely) and so callers can query it via
      # `nix build .#<host>.runtimeSystem`.
      runtimeSystem = selectedRuntime.config.system.build.toplevel;
    };
in
{
  inherit mkNixosConfig mkFleetRuntimeConfig mkNixosOutputs;
}
