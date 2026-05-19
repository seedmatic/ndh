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
      # Tag vocabulary: NixOS guest VMs advertise role=service (driven
      # by an operator) and kind=nixos.  Strings sourced from the
      # catalog so they stay synchronized with
      # catalog/headscale/acl.hujson.
      nixosTailscaleTagModule =
        { ... }:
        {
          tailscale.tags = [
            catalog.headscale.tags.role.headless
            catalog.headscale.tags.kind.nixos
          ];
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
          # Same tag vocabulary as the top-level module — see the
          # explanatory comment above.
          nixosTailscaleTagModule =
            { ... }:
            {
              tailscale.tags = [
                catalog.headscale.tags.role.headless
                catalog.headscale.tags.kind.nixos
              ];
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

      # Full runtime systems (activated remotely via nixos-rebuild switch
      # --target-host once the minimal bringup image is up).
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

      # Minimal bringup system — ZFS + network + SSH only.  The image
      # bytes are bit-identical for every host on the fleet (no
      # hostProfile-derived bake): hostName is the literal
      # "nerd-nixos", hostId is a placeholder, runtimeSystemPath is
      # absent.  Per-host identity is injected at first boot by the
      # per-host Tart bootstrap installer via cloud-init userdata
      # (cidata ISO mechanism).
      #
      # The bringup-minimal config receives a generic ndh.context
      # carrying only the catalog user and the inventory (the
      # latter for ssh-keys-enrichment's authorized_principals
      # seed, which is fleet-shared).  See
      # docs/bringup-image-unification.adoc for the design.
      minimalBringupSystemBase = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
        specialArgs = { inherit self; };
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
                # in modules/.common.d/io-nxmatic-nix-darwin-home-bringup-runtime.nix.
                bringupRuntimeProfilePath = "/nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bringup-runtime";
              };
              store = ndhStoreApiLinux;
            };
          }
        ];
      };

      # The bringup config is identity-less, so the lima/tart variants
      # produce identical store paths (Nix dedups).  Aliases retained
      # for source-level clarity at the call sites.
      limaBringupSystemdZfs = minimalBringupSystemBase;
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

      # Bringup image is identity-less (see minimalBringupSystemBase): the
      # bytes are bit-identical for every host on the fleet.  Use a fixed
      # host-agnostic derivation name ("nerd-bringup-…") so nix actually
      # dedups the build across hosts — without this, `${mainName}-…`
      # produces distinct store paths even when the contents match, and
      # downstream consumers (deploy bundles, gcroots) end up duplicated.
      diskImageBringupZfsSystemdBootRaw = mkBringupZfsDiskImages {
        nixosSystem = selectedBringupSystemdZfs;
        name = "nerd-bringup-zfs-disk-images-raw";
        hostLabel = "nerd";
        # No runtime system closure — minimal bringup only
        runtimeSystemPath = null;
        inherit pauseAfterInstall;
        inherit enableBuildObserve;
        inherit buildObserveInterval;
      };

      diskImageBringupZfsSystemdBoot = mkDiskImageWithManifest {
        attr = "nerd-bringup-zfs-disk-images";
        nixosConfiguration = "nerd-bringup";
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
        # Full runtime systems (what the operator activates post-bringup via
        # nixos-rebuild switch --target-host)
        "${mainName}-lima" = zfsRuntimeLima;
        "${mainName}-tart" = zfsRuntimeTart;
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
  inherit mkNixosConfig mkNixosOutputs;
}
