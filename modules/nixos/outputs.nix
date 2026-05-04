{
  nixpkgs,
  pkgsForLinux,
  ndhStoreApiLinux,
  ndhNixBashTrampolineLinux,
  mkModulesFor,
  mkSpecialArgs,
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
        nixosBringupRootFs = selectedBringupRootFs;
      };

      # ZFS bringup always uses "zfs" as the root FS type regardless of the
      # host's default selectedBringupRootFs (which defaults to "btrfs").
      # Without this, boot.initrd.systemd.root would be "gpt-auto" (the
      # NixOS default for non-ZFS roots), causing a 90s initrd timeout.
      bringupSystemdZfsHostProfileBase = bringupSystemdHostProfileBase // {
        nixosBringupRootFs = "zfs";
      };

      bringupGrubZfsHostProfileBase = bringupGrubHostProfileBase // {
        nixosBringupRootFs = "zfs";
      };

      runtimeSystemdHostProfile = hostProfile // {
        nixosBootLoader = "systemd-boot";
      };

      selectedVmProvider = hostProfile.vmProvider or "tart";
      selectedBringupRootFs = hostProfile.nixosBringupRootFs or "btrfs";

      bringupGrubHostProfileBase = hostProfile // {
        nixosBootLoader = "grub";
        nixosBringupRootFs = selectedBringupRootFs;
      };

      rootFsOverrideModule =
        { lib, ... }:
        {
          fileSystems."/".fsType = lib.mkForce selectedBringupRootFs;
        };

      limaBringupSystemdHostProfile = bringupSystemdHostProfileBase // {
        vmProvider = "lima";
      };

      tartBringupSystemdHostProfile = bringupSystemdHostProfileBase // {
        vmProvider = "tart";
      };

      limaBringupGrubHostProfile = bringupGrubHostProfileBase // {
        vmProvider = "lima";
      };

      tartBringupGrubHostProfile = bringupGrubHostProfileBase // {
        vmProvider = "tart";
      };

      limaBringupSystemdModules = mkImageModulesFor {
        hp = limaBringupSystemdHostProfile;
        generationMode = "bringup";
      };
      limaBringupSystemdSpecialArgs =
        mkImageSpecialArgsFor limaBringupSystemdHostProfile "bringup"
          limaBringupSystemdModules;

      limaBringupSystemd = nixpkgs.lib.nixosSystem {
        modules = limaBringupSystemdModules;
        specialArgs = limaBringupSystemdSpecialArgs;
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
      };

      tartBringupSystemdModules = mkImageModulesFor {
        hp = tartBringupSystemdHostProfile;
        generationMode = "bringup";
      };
      tartBringupSystemdSpecialArgs =
        mkImageSpecialArgsFor tartBringupSystemdHostProfile "bringup"
          tartBringupSystemdModules;

      tartBringupSystemd = nixpkgs.lib.nixosSystem {
        modules = tartBringupSystemdModules;
        specialArgs = tartBringupSystemdSpecialArgs;
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
      };

      limaBringupGrubModules = mkImageModulesFor {
        hp = limaBringupGrubHostProfile;
        generationMode = "bringup";
      };
      limaBringupGrubSpecialArgs =
        mkImageSpecialArgsFor limaBringupGrubHostProfile "bringup"
          limaBringupGrubModules;

      limaBringupGrub = nixpkgs.lib.nixosSystem {
        modules = limaBringupGrubModules;
        specialArgs = limaBringupGrubSpecialArgs;
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
      };

      tartBringupGrubModules = mkImageModulesFor {
        hp = tartBringupGrubHostProfile;
        generationMode = "bringup";
      };
      tartBringupGrubSpecialArgs =
        mkImageSpecialArgsFor tartBringupGrubHostProfile "bringup"
          tartBringupGrubModules;

      tartBringupGrub = nixpkgs.lib.nixosSystem {
        modules = tartBringupGrubModules;
        specialArgs = tartBringupGrubSpecialArgs;
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
      };

      limaBringupSystemdZfs = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        generationMode = "bringup";
        hostProfile = bringupSystemdZfsHostProfileBase;
        zfsOverlays = true;
        vmProvider = "lima";
        # Thread production system closure so zfs-nixos-install can use prebuilt path.
        runtimeSystemPath = selectedRuntime.config.system.build.toplevel;
      };

      tartBringupSystemdZfs = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        generationMode = "bringup";
        hostProfile = bringupSystemdZfsHostProfileBase;
        zfsOverlays = true;
        vmProvider = "tart";
        runtimeSystemPath = selectedRuntime.config.system.build.toplevel;
      };

      limaBringupGrubZfs = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        generationMode = "bringup";
        hostProfile = bringupGrubZfsHostProfileBase;
        # ZFS bringup path: enable ZFS-backed filesystem definitions/boot integration.
        zfsOverlays = true;
        vmProvider = "lima";
      };

      tartBringupGrubZfs = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        generationMode = "bringup";
        hostProfile = bringupGrubZfsHostProfileBase;
        # ZFS bringup path: enable ZFS-backed filesystem definitions/boot integration.
        zfsOverlays = true;
        vmProvider = "tart";
      };

      zfsRuntimeLima = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        generationMode = "full";
        hostProfile = runtimeSystemdHostProfile;
        # Lima runtime: ZFS root + stage1 disko provisioning path.
        zfsOverlays = true;
        vmProvider = "lima";
      };

      zfsRuntimeTart = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        generationMode = "full";
        hostProfile = runtimeSystemdHostProfile;
        # Tart runtime with ZFS-backed filesystem definitions/boot integration enabled.
        zfsOverlays = true;
        vmProvider = "tart";
      };

      selectedRuntime = if selectedVmProvider == "tart" then zfsRuntimeTart else zfsRuntimeLima;

      runtimeImageModules = mkImageModulesFor {
        hp = runtimeSystemdHostProfile;
        generationMode = "full";
      };
      runtimeImageSpecialArgs =
        mkImageSpecialArgsFor runtimeSystemdHostProfile "full"
          runtimeImageModules;
      bringupSystemdImageModules = mkImageModulesFor {
        hp = bringupSystemdHostProfileBase;
        generationMode = "bringup";
      };
      bringupSystemdImageSpecialArgs =
        mkImageSpecialArgsFor bringupSystemdHostProfileBase "bringup"
          bringupSystemdImageModules;
      bringupGrubImageModules = mkImageModulesFor {
        hp = bringupGrubHostProfileBase;
        generationMode = "bringup";
      };
      bringupGrubImageSpecialArgs =
        mkImageSpecialArgsFor bringupGrubHostProfileBase "bringup"
          bringupGrubImageModules;

      # Canonical raw build image size policy.
      # - `uncompressedDiskSizeGiB` is the baseline required without compression.
      # - A single compression factor is currently used.
      # - For zstd level 1, we model a 0.5 factor (2:1 compression).
      # - Future per-filesystem factors may override rootFsCompressionFactor,
      #   but should default to zstdCompressionFactor.
      uncompressedDiskSizeGiB = hostProfile.nixosDiskImageSizeGiB or 16;
      selectedZstdCompressionLevel = hostProfile.nixosZstdCompressionLevel or 1;
      zstdCompressionFactor = if selectedZstdCompressionLevel == 1 then 0.5 else 1.0;
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
      zfsBootstrapPoolDiskSizeMiB = hostProfile.nixosZfsBootstrapPoolDiskSizeMiB or 2048;
      # ZFS vdev disk size for the bringup QEMU build VM.
      # Derived from uncompressedDiskSizeGiB (no compression factor — ZFS handles
      # compression internally per-dataset). Accounts for raidz1 overhead (3 disks,
      # 1 parity: usable = 2 × zfs_partition_size) and per-disk EFI/GPT overhead
      # (espStart=1 MiB + efiSystemPartitionSizeMiB + 1 MiB GPT backup = +2 beyond EFI).
      zpoolVdevDiskSizeMiB = hostProfile.nixosZpoolVdevDiskSizeMiB or (
        builtins.ceil (uncompressedDiskSizeGiB * 512.0) + efiSystemPartitionSizeMiB + 2
      );
      # Bringup closure paths used for stage-1/2 bringup sizing checks.
      bringupRootFsType = selectedBringupRootFs;
      bringupRootFsName = bringupRootFsType;
      bringupSystemPath = tartBringupSystemd.config.system.build.toplevel;
      bringupZfsSystemPath = tartBringupSystemdZfs.config.system.build.toplevel;
      # Output a JSON hint with all relevant info for post-build checks
      diskSizeHint = builtins.toJSON {
        systemPath = bringupZfsSystemPath;
        bringupSystemPaths = {
          bringup = bringupSystemPath;
          zfs = bringupZfsSystemPath;
        };
        diskSizeBytes = diskSizeBytes;
        diskSizing = {
          uncompressedDiskSizeGiB = uncompressedDiskSizeGiB;
          selectedBringupRootFs = selectedBringupRootFs;
          zstdCompressionLevel = selectedZstdCompressionLevel;
          zstdCompressionFactor = zstdCompressionFactor;
          rootFsCompressionFactor = rootFsCompressionFactor;
          finalDiskSizeGiB = diskSizeGiB;
        };
        diskSizeMiB = {
          runtime = diskSizeMiB;
          bringupSystemdBoot = diskSizeMiB;
          bringupGrub = diskSizeMiB;
          zpoolVdevDisk = zpoolVdevDiskSizeMiB;
        };
        diskImageVmResources = {
          memSizeMiB = diskImageVmMemSizeMiB;
          cpuCores = diskImageVmCpuCores;
        };
        efiSystemPartitionSizeMiB = efiSystemPartitionSizeMiB;
        hint = {
          bringup = "nix path-info -Sh ${bringupSystemPath}";
          zfsBringup = "nix path-info -Sh ${bringupZfsSystemPath}";
        };
        note = "bringup closure sizes should be less than diskSizeBytes; inspect boot-size-hint.yaml in image outputs to tune ESP size from measured single-generation usage";
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
          manifestBaseYamlFile = pkgsForLinux.runCommand "nixos-disk-image-manifest-base-${attr}.yaml" {
            nativeBuildInputs = [ pkgsForLinux.yq-go ];
            passAsFile = [ "manifestAttrsJson" ];
            inherit manifestAttrsJson;
          } ''yq -p json -o yaml "$manifestAttrsJsonPath" > "$out"'';
          extraImagesSpecYamlFile = pkgsForLinux.runCommand "nixos-disk-image-extra-images-${attr}.yaml" {
            nativeBuildInputs = [ pkgsForLinux.yq-go ];
            passAsFile = [ "extraImagesJson" ];
            extraImagesJson = builtins.toJSON extraImages;
          } ''yq -p json -o yaml "$extraImagesJsonPath" > "$out"'';
          manifestAssemblyScript = pkgsForLinux.replaceVars ./mk-disk-image-with-manifest.sh {
            nixBashTrampoline = "${ndhNixBashTrampoline}";
            loggerTag = "nixos.outputs.mkDiskImageWithManifest.${attr}";
          };
        in
        pkgsForLinux.runCommand "nixos-disk-image-with-manifest-${attr}"
          {
            nativeBuildInputs = [ pkgsForLinux.yq-go ];
            NDH_PRIMARY_IMAGE_PATH = primaryImagePath;
            NDH_MANIFEST_BASE_YAML_FILE = manifestBaseYamlFile;
            NDH_EXTRA_IMAGES_SPEC_YAML_FILE = extraImagesSpecYamlFile;
          }
          ''
            set -euo pipefail

            ${pkgsForLinux.bash}/bin/bash ${manifestAssemblyScript} "$out" "${source}"
          '';

      mkBringupRawImage =
        {
          nixosSystem,
          name,
        }:
        import ./bringup-btrfs-disk-image.nix {
          lib = nixpkgs.lib;
          pkgs = pkgsForLinux;
          config = nixosSystem.config;
          diskSize = diskSizeMiB;
          memSize = diskImageVmMemSizeMiB;
          vmCpuCores = diskImageVmCpuCores;
          includeChannel = false;
          efiSystemPartitionSizeMiB = efiSystemPartitionSizeMiB;
          inherit name;
          rootFsType = "${bringupRootFsType}";
          rootFsLabel = "nixos";
        };

      mkBringupZfsDiskImages =
        {
          nixosSystem,
          name,
          runtimeSystemPath ? null,
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
          zpoolDiskSize = zpoolVdevDiskSizeMiB;
          memSize = diskImageVmMemSizeMiB;
          vmCpuCores = diskImageVmCpuCores;
          includeChannel = false;
          inherit name;
        };

      diskImageBringupSystemdBootRaw = mkBringupRawImage {
        nixosSystem = limaBringupSystemd;
        name = "nixos-disk-image-bringup-systemd-${bringupRootFsType}";
      };

      # ZFS bringup image selected by vmProvider — Lima and Tart differ in guest-side units.
      selectedBringupSystemdZfs = if selectedVmProvider == "tart" then tartBringupSystemdZfs else limaBringupSystemdZfs;

      diskImageBringupZfsSystemdBootRaw = mkBringupZfsDiskImages {
        nixosSystem = selectedBringupSystemdZfs;
        name = "nixos-disk-image-bringup-systemd-zfs";
        runtimeSystemPath = selectedRuntime.config.system.build.toplevel;
      };

      diskImageBringupGrubRaw = mkBringupRawImage {
        nixosSystem = limaBringupGrub;
        name = "nixos-disk-image-bringup-grub-${bringupRootFsType}";
      };

      diskImageFullRaw = mkBringupRawImage {
        nixosSystem = selectedRuntime;
        name = "nixos-disk-image-full-${bringupRootFsType}";
      };

      diskImageBringupSystemdBoot = mkDiskImageWithManifest {
        attr = "nixosDiskImageBringupSystemdBoot";
        nixosConfiguration = "${mainName}-nixos-lima-bringup-systemd-${bringupRootFsName}";
        imageMode = "bringup";
        bootLoader = "systemd-boot";
        diskSizeMiB = diskSizeMiB;
        efiSystemPartitionSizeMiB = efiSystemPartitionSizeMiB;
        source = diskImageBringupSystemdBootRaw;
      };

      diskImageBringupZfsSystemdBoot = mkDiskImageWithManifest {
        attr = "nixosDiskImageBringupZfsSystemdBoot";
        nixosConfiguration = "${mainName}-nixos-${selectedVmProvider}";
        imageMode = "bringup";
        bootLoader = "systemd-boot";
        diskSizeMiB = diskSizeMiB;
        efiSystemPartitionSizeMiB = efiSystemPartitionSizeMiB;
        source = diskImageBringupZfsSystemdBootRaw;
        # primaryImagePath defaults to "boot.img" — dedicated EFI boot disk
        # zpools is populated at runtime from boot-size-hint.yaml (zpool status inside QEMU)
      };

      diskImageBringupGrub = mkDiskImageWithManifest {
        attr = "nixosDiskImageBringupGrub";
        nixosConfiguration = "${mainName}-nixos-lima-bringup-grub-${bringupRootFsName}";
        imageMode = "bringup";
        bootLoader = "grub";
        diskSizeMiB = diskSizeMiB;
        efiSystemPartitionSizeMiB = efiSystemPartitionSizeMiB;
        source = diskImageBringupGrubRaw;
      };

      diskImageFull = mkDiskImageWithManifest {
        attr = "nixosDiskImage";
        nixosConfiguration = "${mainName}-nixos";
        imageMode = "full";
        bootLoader = "systemd-boot";
        diskSizeMiB = diskSizeMiB;
        efiSystemPartitionSizeMiB = efiSystemPartitionSizeMiB;
        source = diskImageFullRaw;
      };

    in
    {
      inherit diskSizeHint;
      inherit diskSizeGiB;
      inherit diskSizeMiB;
      nixosConfigurations = {
        "${mainName}-nixos-lima-bringup-systemd-${bringupRootFsName}" = limaBringupSystemd;
        "${mainName}-nixos-tart-bringup-systemd-${bringupRootFsName}" = tartBringupSystemd;
        "${mainName}-nixos-lima-bringup-systemd-zfs" = limaBringupSystemdZfs;
        "${mainName}-nixos-tart-bringup-systemd-zfs" = tartBringupSystemdZfs;
        "${mainName}-nixos-lima-bringup-grub-${bringupRootFsName}" = limaBringupGrub;
        "${mainName}-nixos-tart-bringup-grub-${bringupRootFsName}" = tartBringupGrub;
        "${mainName}-nixos-lima-bringup-grub-zfs" = limaBringupGrubZfs;
        "${mainName}-nixos-tart-bringup-grub-zfs" = tartBringupGrubZfs;
        "${mainName}-nixos-lima" = zfsRuntimeLima;
        "${mainName}-nixos-tart" = zfsRuntimeTart;
        "${mainName}-nixos" = selectedRuntime;
      };
      inherit
        diskImageFull
        diskImageBringupSystemdBoot
        diskImageBringupZfsSystemdBoot
        diskImageBringupGrub
        ;
    };
in
{
  inherit mkNixosConfig mkNixosOutputs;
}
