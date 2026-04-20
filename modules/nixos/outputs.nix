{
  nixpkgs,
  pkgsForLinux,
  mkModulesFor,
  mkSpecialArgs,
}:
let
  mkNixosConfig =
    {
      hostProfile,
      profileModule,
      zfsOverlays,
      catalog,
      inventory,
      vmProvider ? null,
    }:
    let
      hostImageMode = hostProfile.nixosImageMode or "full";
      bringupModeInternal = hostImageMode == "bootstrap";
      effectiveVmProvider = if vmProvider != null then vmProvider else (hostProfile.vmProvider or "lima");
      zfsOverlaysModule =
        { ... }:
        {
          zfsOverlays.override = zfsOverlays;
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
        inherit hostProfile preModules;
        system = "nixos";
      };
      specialArgs = mkSpecialArgs {
        inherit modules;
        system = "aarch64-linux";
        extraArgs = {
          inherit hostProfile;
          inherit catalog;
          inherit inventory;
          vmProvider = effectiveVmProvider;
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
      # Canonical behavior (@codebase): runtime nixos output is always full.
      # Bootstrap remains an explicit disk-image path only.

      mkExt4ModulesFor =
        hp:
        let
          hpImageMode = hp.nixosImageMode or "full";
          hpBringupModeInternal = hpImageMode == "bootstrap";
          hpVmProvider = hp.vmProvider or "lima";
          zfsOverlaysModule =
            { ... }:
            {
              zfsOverlays.override = false;
            };
          nixosTailscaleTagModule =
            { ... }:
            {
              tailscale.tags = [ "nixos" ];
            };
        in
        mkModulesFor {
          hostProfile = hp;
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

      mkExt4SpecialArgsFor =
        hp: modules:
        mkSpecialArgs {
          inherit modules;
          system = "aarch64-linux";
          extraArgs = {
            hostProfile = hp;
            inherit catalog;
            inherit inventory;
            vmProvider = hp.vmProvider or "lima";
          };
        };

      bringupSystemdHostProfileBase = hostProfile // {
        nixosImageMode = "bootstrap";
        nixosBootLoader = "systemd-boot";
      };

      runtimeSystemdHostProfile = hostProfile // {
        nixosImageMode = "full";
        nixosBootLoader = "systemd-boot";
      };

      selectedVmProvider = hostProfile.vmProvider or "lima";

      bringupGrubHostProfileBase = hostProfile // {
        nixosImageMode = "bootstrap";
        nixosBootLoader = "grub";
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

      limaBringupSystemdExt4Modules = mkExt4ModulesFor limaBringupSystemdHostProfile;
      limaBringupSystemdExt4SpecialArgs = mkExt4SpecialArgsFor limaBringupSystemdHostProfile limaBringupSystemdExt4Modules;

      limaBringupSystemdExt4 = nixpkgs.lib.nixosSystem {
        modules = limaBringupSystemdExt4Modules;
        specialArgs = limaBringupSystemdExt4SpecialArgs;
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
      };

      tartBringupSystemdExt4Modules = mkExt4ModulesFor tartBringupSystemdHostProfile;
      tartBringupSystemdExt4SpecialArgs = mkExt4SpecialArgsFor tartBringupSystemdHostProfile tartBringupSystemdExt4Modules;

      tartBringupSystemdExt4 = nixpkgs.lib.nixosSystem {
        modules = tartBringupSystemdExt4Modules;
        specialArgs = tartBringupSystemdExt4SpecialArgs;
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
      };

      limaBringupGrubExt4Modules = mkExt4ModulesFor limaBringupGrubHostProfile;
      limaBringupGrubExt4SpecialArgs = mkExt4SpecialArgsFor limaBringupGrubHostProfile limaBringupGrubExt4Modules;

      limaBringupGrubExt4 = nixpkgs.lib.nixosSystem {
        modules = limaBringupGrubExt4Modules;
        specialArgs = limaBringupGrubExt4SpecialArgs;
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
      };

      tartBringupGrubExt4Modules = mkExt4ModulesFor tartBringupGrubHostProfile;
      tartBringupGrubExt4SpecialArgs = mkExt4SpecialArgsFor tartBringupGrubHostProfile tartBringupGrubExt4Modules;

      tartBringupGrubExt4 = nixpkgs.lib.nixosSystem {
        modules = tartBringupGrubExt4Modules;
        specialArgs = tartBringupGrubExt4SpecialArgs;
        system = "aarch64-linux";
        pkgs = pkgsForLinux;
      };

      limaBringupSystemdZfs = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        hostProfile = bringupSystemdHostProfileBase;
        zfsOverlays = true;
        vmProvider = "lima";
      };

      tartBringupSystemdZfs = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        hostProfile = bringupSystemdHostProfileBase;
        zfsOverlays = true;
        vmProvider = "tart";
      };

      limaBringupGrubZfs = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        hostProfile = bringupGrubHostProfileBase;
        zfsOverlays = true;
        vmProvider = "lima";
      };

      tartBringupGrubZfs = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        hostProfile = bringupGrubHostProfileBase;
        zfsOverlays = true;
        vmProvider = "tart";
      };

      zfsRuntimeLima = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        hostProfile = runtimeSystemdHostProfile;
        zfsOverlays = true;
        vmProvider = "lima";
      };

      zfsRuntimeTart = mkNixosConfig {
        inherit
          profileModule
          catalog
          inventory
          ;
        hostProfile = runtimeSystemdHostProfile;
        zfsOverlays = true;
        vmProvider = "tart";
      };

      selectedRuntime = if selectedVmProvider == "tart" then zfsRuntimeTart else zfsRuntimeLima;

      runtimeExt4Modules = mkExt4ModulesFor runtimeSystemdHostProfile;
      runtimeExt4SpecialArgs = mkExt4SpecialArgsFor runtimeSystemdHostProfile runtimeExt4Modules;
      bringupSystemdImageExt4Modules = mkExt4ModulesFor bringupSystemdHostProfileBase;
      bringupSystemdImageExt4SpecialArgs = mkExt4SpecialArgsFor bringupSystemdHostProfileBase bringupSystemdImageExt4Modules;
      bringupGrubImageExt4Modules = mkExt4ModulesFor bringupGrubHostProfileBase;
      bringupGrubImageExt4SpecialArgs = mkExt4SpecialArgsFor bringupGrubHostProfileBase bringupGrubImageExt4Modules;

      # Canonical disk size in MiB shared by all disk-image profiles.
      # Keep one source of truth to avoid host/guest sizing drift.
      diskSizeMiB = (4 + 2) * 1024; # 4GiB base + 2GiB buffer for growth and closure size uncertainty
      diskSizeBytes = diskSizeMiB * 1024 * 1024;
      # Bringup closure paths used for stage-1/2 bootstrap sizing checks.
      bringupExt4SystemPath = tartBringupSystemdExt4.config.system.build.toplevel;
      bringupZfsSystemPath = tartBringupSystemdZfs.config.system.build.toplevel;
      # Output a JSON hint with all relevant info for post-build checks
      diskSizeHint = builtins.toJSON {
        systemPath = bringupZfsSystemPath;
        bringupSystemPaths = {
          ext4 = bringupExt4SystemPath;
          zfs = bringupZfsSystemPath;
        };
        diskSizeBytes = diskSizeBytes;
        diskSizeMiB = {
          runtime = diskSizeMiB;
          bringupSystemdBoot = diskSizeMiB;
          bringupGrub = diskSizeMiB;
        };
        hint = {
          ext4Bringup = "nix path-info -Sh ${bringupExt4SystemPath}";
          zfsBringup = "nix path-info -Sh ${bringupZfsSystemPath}";
        };
        note = "bringup closure sizes should be less than diskSizeBytes";
      };
      mainName =
        if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
          hostProfile.hostAlias
        else
          hostProfile.hostName;

      mkDiskImageManifestYaml =
        {
          attr,
          imageMode,
          bootLoader,
          diskSizeMiB,
          sourceOutPath,
          nixosConfiguration,
        }:
        ''
          schemaVersion: 1
          kind: nixos-disk-image
          attr: ${attr}
          nixosConfiguration: ${nixosConfiguration}
          imageMode: ${imageMode}
          bootLoader: ${bootLoader}
          format: raw-efi
          imagePath: nixos.img
          sourceOutPath: ${sourceOutPath}
          diskSizeMiB: ${toString diskSizeMiB}
        '';

      mkDiskImageWithManifest =
        {
          attr,
          imageMode,
          bootLoader,
          diskSizeMiB,
          nixosConfiguration,
          source,
        }:
        pkgsForLinux.runCommand "nixos-disk-image-with-manifest-${attr}" { } ''
          set -euo pipefail
          mkdir -p "$out"

          source_image=""

          if [[ -f "${source}/nixos.img" ]]; then
            source_image="${source}/nixos.img"
          elif [[ -f "${source}" ]]; then
            source_image="${source}"
          elif [[ -f "${source}/nix-support/hydra-build-products" ]]; then
            source_image=$(awk '$1 == "file" && $2 ~ /image|img/ { print $3; exit }' "${source}/nix-support/hydra-build-products")
          fi

          if [[ -z "$source_image" && -d "${source}" ]]; then
            source_image=$(find "${source}" -maxdepth 1 -type f -name '*.img' | head -n1 || true)
          fi

          if [[ -z "$source_image" || ! -f "$source_image" ]]; then
            echo "[flake][ERROR] unsupported disk image source shape for ${attr}: ${source}" >&2
            echo "[flake][ERROR] expected one of: ${source}/nixos.img, direct file, hydra-build-products image entry, or *.img in source root" >&2
            exit 1
          fi

          ln -s "$source_image" "$out/nixos.img"

          cat >"$out/manifest.yaml" <<'EOF'
          ${mkDiskImageManifestYaml {
            inherit
              attr
              imageMode
              bootLoader
              diskSizeMiB
              nixosConfiguration
              ;
            sourceOutPath = source;
          }}
          EOF
        '';

      mkRawEfiImage =
        {
          modules,
          specialArgs,
        }:
        let
          imageNixosSystem = nixpkgs.lib.nixosSystem {
            inherit modules specialArgs;
            system = "aarch64-linux";
            pkgs = pkgsForLinux;
          };
        in
        imageNixosSystem.config.system.build.images."raw-efi";

      diskImageBringupSystemdExt4BootRaw = mkRawEfiImage {
        modules = bringupSystemdImageExt4Modules ++ [
          {
            nix.registry.nixpkgs.flake = nixpkgs;
            virtualisation.diskSize = diskSizeMiB;
          }
        ];
        specialArgs = bringupSystemdImageExt4SpecialArgs;
      };

      diskImageBringupZfsSystemdBootRaw = tartBringupSystemdZfs.config.system.build.images."raw-efi";

      diskImageBringupGrubRaw = mkRawEfiImage {
        modules = bringupGrubImageExt4Modules ++ [
          {
            nix.registry.nixpkgs.flake = nixpkgs;
            virtualisation.diskSize = diskSizeMiB;
          }
        ];
        specialArgs = bringupGrubImageExt4SpecialArgs;
      };

      diskImageFullRaw = mkRawEfiImage {
        modules = runtimeExt4Modules ++ [
          {
            nix.registry.nixpkgs.flake = nixpkgs;
            virtualisation.diskSize = diskSizeMiB;
          }
        ];
        specialArgs = runtimeExt4SpecialArgs;
      };

      diskImageBringupSystemdExt4Boot = mkDiskImageWithManifest {
        attr = "nixosdiskImageBringupSystemdExt4Boot";
        nixosConfiguration = "lima-${mainName}-bringup-systemd-ext4";
        imageMode = "bootstrap";
        bootLoader = "systemd-boot";
        diskSizeMiB = diskSizeMiB;
        source = diskImageBringupSystemdExt4BootRaw;
      };

      diskImageBringupZfsSystemdBoot = mkDiskImageWithManifest {
        attr = "nixosDiskImageBringupZfsSystemdBoot";
        nixosConfiguration = "tart-${mainName}-bringup-systemd-zfs";
        imageMode = "bootstrap";
        bootLoader = "systemd-boot";
        diskSizeMiB = diskSizeMiB;
        source = diskImageBringupZfsSystemdBootRaw;
      };

      diskImageBringupGrub = mkDiskImageWithManifest {
        attr = "nixosDiskImageBringupGrub";
        nixosConfiguration = "lima-${mainName}-bringup-grub-ext4";
        imageMode = "bootstrap";
        bootLoader = "grub";
        diskSizeMiB = diskSizeMiB;
        source = diskImageBringupGrubRaw;
      };

      diskImageFull = mkDiskImageWithManifest {
        attr = "nixosDiskImage";
        nixosConfiguration = "${mainName}-nixos";
        imageMode = "full";
        bootLoader = "systemd-boot";
        diskSizeMiB = diskSizeMiB;
        source = diskImageFullRaw;
      };

    in
    {
      inherit diskSizeHint;
      inherit diskSizeMiB;
      nixosConfigurations = {
        "lima-${mainName}-bringup-systemd-ext4" = limaBringupSystemdExt4;
        "tart-${mainName}-bringup-systemd-ext4" = tartBringupSystemdExt4;
        "lima-${mainName}-bringup-systemd-zfs" = limaBringupSystemdZfs;
        "tart-${mainName}-bringup-systemd-zfs" = tartBringupSystemdZfs;
        "lima-${mainName}-bringup-grub-ext4" = limaBringupGrubExt4;
        "tart-${mainName}-bringup-grub-ext4" = tartBringupGrubExt4;
        "lima-${mainName}-bringup-grub-zfs" = limaBringupGrubZfs;
        "tart-${mainName}-bringup-grub-zfs" = tartBringupGrubZfs;
        "${mainName}-nixos-lima" = zfsRuntimeLima;
        "${mainName}-nixos-tart" = zfsRuntimeTart;
        "${mainName}-nixos" = selectedRuntime;
      };
      inherit
        diskImageFull
        diskImageBringupSystemdExt4Boot
        diskImageBringupZfsSystemdBoot
        diskImageBringupGrub
        ;
    };
in
{
  inherit mkNixosConfig mkNixosOutputs;
}
