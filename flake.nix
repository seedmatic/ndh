{
  description = "nix system configurations";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://nxmatic.cachix.org"
      "https://cache.flox.dev"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nxmatic.cachix.org-1:huMghYiwDpPa1PMXHXK4G1Dp4QOZjgsNqxcjf/AjuJ0="
      "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
    ];
  };

  inputs = {
    flake-commons.url = "github:nxmatic/nix-flake-commons/develop";
    flake-compat.follows = "flake-commons/flake-compat";
    flake-utils.follows = "flake-commons/flake-utils";
    nix.follows = "flake-commons/nix";
    lix-module.follows = "flake-commons/lix-module";
    nixos-hardware.follows = "flake-commons/nixos-hardware";
    nixpkgs.follows = "flake-commons/nixpkgs";
    cachix.follows = "flake-commons/cachix";
    darwin.follows = "flake-commons/darwin";
    home-manager.follows = "flake-commons/home-manager";
    devenv.follows = "flake-commons/devenv";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    bird.follows = "flake-commons/bird";
    maven-mvnd.follows = "flake-commons/maven-mvnd";
    socket-vmnet.follows = "flake-commons/socket-vmnet";
    zen-browser.follows = "flake-commons/zen-browser";
    ripvcs.follows = "flake-commons/ripvcs";
    chromium-bin.follows = "flake-commons/chromium-bin";
    disko.follows = "flake-commons/disko";
    impermanence.follows = "flake-commons/impermanence";
    incus-compose.follows = "flake-commons/incus-compose";
    sops-nix.url = "github:Mic92/sops-nix";
  };

  outputs =
    {
      self,
      darwin,
      devenv,
      flake-utils,
      home-manager,
      disko,
      socket-vmnet,
      impermanence,
      nixpkgs,
      ...
    }@inputs:
    let
      inherit (flake-utils.lib) eachSystemMap;
      nixpkgsConfig = import ./modules/.common.d/nixpkgs-config.nix;
      cacheTrust = import ./catalog/cache-trust.nix;
      defaultSystems = [
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs defaultSystems;

      pkgsFor =
        { system, ... }:
        let
          basePackages = import nixpkgs {
            inherit system;
            config = nixpkgsConfig // {
              allowBroken = true;
              checkAllPackages = false;
            };
          };

          vmnetOverlay =
            final: prev:
            if inputs.socket-vmnet.packages ? ${system} then
              inputs.socket-vmnet.packages.${system}
            else
              throw "Socket VMNet packages not defined for ${system}";

          ripvcsOverlay =
            final: prev:
            if inputs.ripvcs.packages ? ${system} then
              inputs.ripvcs.packages.${system}
            else
              throw "Ripvcs packages not defined for ${system}";

          overlays = builtins.map (
            name:
            let
              overlay = self.overlays.${name} inputs;
            in
            final: prev: overlay final prev
          ) (builtins.attrNames self.overlays);

          applyOverlays =
            final: prev: builtins.foldl' (acc: overlay: (acc // (overlay final prev))) { } overlays;
        in
        basePackages.extend (
          final: prev: (vmnetOverlay final prev) // (ripvcsOverlay final prev) // (applyOverlays final prev)
        );
      pkgsForDarwin = (pkgsFor { system = "aarch64-darwin"; });
      pkgsForLinux = (pkgsFor { system = "aarch64-linux"; });

      mkNdhStoreApiFor =
        pkgsForSystem:
        let
          storeNamePrefix = "io.nxmatic.nix-darwin-home";
          prefixStoreName =
            name:
            if nixpkgs.lib.hasPrefix "${storeNamePrefix}-" name then name else "${storeNamePrefix}-${name}";
        in
        rec {
          prefix = storeNamePrefix;
          prefixedName = prefixStoreName;
          installScript =
            {
              name,
              source,
              preferLocalBuild ? null,
              allowSubstitutes ? null,
              mode ? "0555",
            }:
            pkgsForSystem.runCommand (prefixedName name)
              (
                (nixpkgs.lib.optionalAttrs (preferLocalBuild != null) { inherit preferLocalBuild; })
                // (nixpkgs.lib.optionalAttrs (allowSubstitutes != null) { inherit allowSubstitutes; })
              )
              ''
                install -m ${mode} ${source} "$out"
              '';
          runCommand =
            name: attrs: text:
            pkgsForSystem.runCommand (prefixedName name) attrs text;
          writeText = name: text: pkgsForSystem.writeText (prefixedName name) text;
          writeShellScript = name: text: pkgsForSystem.writeShellScript (prefixedName name) text;
        };

      ndhStoreApiDarwin = mkNdhStoreApiFor pkgsForDarwin;
      ndhStoreApiLinux = mkNdhStoreApiFor pkgsForLinux;

      mkBaseModulesFor =
        { hostProfile, system }:
        let
          hostImageMode = hostProfile.nixosImageMode or "full";
          bringupModeInternal = hostImageMode == "bootstrap";
          requestedHomeManagerEnabled =
            if hostProfile ? enableHomeManager && hostProfile.enableHomeManager != null then
              hostProfile.enableHomeManager
            else
              true;
          homeManagerEnabled =
            if system == "nixos" && bringupModeInternal then false else requestedHomeManagerEnabled;
        in
        [
          {
            limaHost.hostName =
              if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
                hostProfile.hostAlias
              else
                hostProfile.hostName;
          }
        ]
        ++ (
          if system == "nixos" then
            [
              disko.nixosModules.disko
              inputs.sops-nix.nixosModules.sops
            ]
            ++ (if homeManagerEnabled then [ home-manager.nixosModules.home-manager ] else [ ])
            ++ [
              impermanence.nixosModules.impermanence
              ./modules/nixos
            ]
          else if system == "darwin" then
            [
              inputs.sops-nix.darwinModules.sops
              home-manager.darwinModules.home-manager
              # Only include impermanence if darwinModules exists
            ]
            ++ (if impermanence ? darwinModules then [ impermanence.darwinModules.impermanence ] else [ ])
            ++ [ ./modules/darwin ]
          else
            [ ]
        );
      mkModulesFor =
        {
          hostProfile,
          system,
          preModules ? [ ],
          extraModules ? [ ],
          ...
        }:
        let
          baseModules = mkBaseModulesFor { inherit hostProfile system; };
        in
        preModules ++ baseModules ++ extraModules;

      mkLoggerSpecialArg =
        system:
        let
          pkgsForSystem = pkgsFor { inherit system; };
          ndhStoreApi = mkNdhStoreApiFor pkgsForSystem;
          loggerScript = ndhStoreApi.writeText "logger.sh" ''
            #!/usr/bin/env bash
            LOGGER_CMD=""
            source ${./modules/.common.d/shell.d/logger.sh}
          '';
        in
        {
          script = loggerScript;
          cmd = "";
        };

      mkNdhBootstrapRuntimePackage =
        system:
        let
          pkgsForSystem = pkgsFor { inherit system; };
          ndhStoreApi = mkNdhStoreApiFor pkgsForSystem;
          bashPackage = pkgsForSystem.lib.getBin pkgsForSystem.bashInteractive;
          nixPackage = pkgsForSystem.lib.getBin pkgsForSystem.nix;
        in
        pkgsForSystem.symlinkJoin {
          name = ndhStoreApi.prefixedName "bringup-runtime-profile-holder";
          paths = with pkgsForSystem; [
            bashPackage
            nixPackage
            age
            coreutils-full
            findutils
            gawk
            git
            gnugrep
            gnused
            keychain
            openssh
            yq-go
          ];
        };

      mkNdhBootstrapProfileInstaller =
        system:
        let
          pkgsForSystem = pkgsFor { inherit system; };
          ndhStoreApi = mkNdhStoreApiFor pkgsForSystem;
          runtimePackage = mkNdhBootstrapRuntimePackage system;
          loggerScript = (mkLoggerSpecialArg system).script;
          scriptSource =
            pkgsForSystem.replaceVars ./modules/.common.d/bootstrap-profile.d/install-standalone.sh
              {
                bash = "${pkgsForSystem.bash}/bin/bash";
                nix = "${pkgsForSystem.nix}/bin/nix";
                bashTrampoline = "${./modules/.common.d/shell.d/nix-bash-trampoline.sh}";
                logger = loggerScript;
                loggerTag = "ndh.bootstrap-profile.install-standalone";
                runtimePackage = runtimePackage;
                defaultProfileDir = "/nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bringup-runtime-profile-holder";
                requiredCommands = "bash nix age age-keygen awk sed grep ssh ssh-keygen yq git";
              };
        in
        ndhStoreApi.runCommand "bringup-runtime-profile-installer" { } ''
          install -Dm755 ${scriptSource} "$out/bin/io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer"
        '';

      mkSpecialArgs =
        {
          modules,
          system,
          extraArgs ? { },
          ...
        }:
        let
          lib = inputs.nixpkgs.lib.extend (
            _: _:
            inputs.home-manager.lib
            // {
              # Any additional lib functions you want to include
            }
          );
        in
        {
          inherit self lib;
          _modules = modules;
          nixpkgsInput = nixpkgs;
          logger = mkLoggerSpecialArg system;
        }
        // extraArgs;

      mkDarwinConfig =
        {
          hostProfile,
          profileModule,
          catalog,
        }:
        let
          preModules = [
            profileModule
            # socket-vmnet.darwinModules.socket_vmnet
            (
              { lib, ... }:
              {
                lima.configGenerator.vmType = "vz";
              }
            )
          ];
          modules = mkModulesFor {
            inherit hostProfile preModules;
            system = "darwin";
          };
          specialArgs = mkSpecialArgs {
            inherit modules;
            system = "aarch64-darwin";
            extraArgs = {
              inherit hostProfile;
              inherit catalog;
            };
          };
        in
        inputs.darwin.lib.darwinSystem {
          inherit specialArgs modules;
          system = "aarch64-darwin";
          pkgs = pkgsForDarwin.extend (
            final: prev: {
              chromium-bin = inputs.chromium-bin.packages."aarch64-darwin".default;
            }
          );
        };
      mkDarwinOutputs =
        {
          hostProfile,
          profileModule,
          catalog,
          ...
        }:
        let
          darwinConfiguration = mkDarwinConfig { inherit hostProfile profileModule catalog; };
          darwinConfigurations = {
            "${hostProfile.hostName}" = darwinConfiguration;
          }
          // (
            if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
              {
                "${hostProfile.hostAlias}" = darwinConfiguration;
              }
            else
              { }
          );
        in
        {
          inherit darwinConfigurations;
        };

      mkNixosConfig =
        {
          hostProfile,
          profileModule,
          zfsOverlays,
          catalog,
        }:
        let
          hostImageMode = hostProfile.nixosImageMode or "full";
          bringupModeInternal = hostImageMode == "bootstrap";
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
        }:
        let
          # Canonical behavior (@codebase): runtime nixos output is always full.
          # Bootstrap remains an explicit disk-image path only.

          mkExt4ModulesFor =
            hp:
            let
              hpImageMode = hp.nixosImageMode or "full";
              hpBringupModeInternal = hpImageMode == "bootstrap";
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
              };
            };

          bootstrapSystemdBootHostProfile = hostProfile // {
            nixosImageMode = "bootstrap";
            nixosBootLoader = "systemd-boot";
          };

          runtimeHostProfile = hostProfile // {
            nixosImageMode = "full";
            nixosBootLoader = "systemd-boot";
          };

          bringupGrubHostProfile = hostProfile // {
            nixosImageMode = "bootstrap";
            nixosBootLoader = "grub";
          };

          ext4Modules = mkExt4ModulesFor bootstrapSystemdBootHostProfile;
          ext4SpecialArgs = mkExt4SpecialArgsFor bootstrapSystemdBootHostProfile ext4Modules;

          ext4 = nixpkgs.lib.nixosSystem {
            modules = ext4Modules;
            specialArgs = ext4SpecialArgs;
            system = "aarch64-linux";
            pkgs = pkgsForLinux;
          };

          zfsBringup = mkNixosConfig {
            inherit
              profileModule
              catalog
              ;
            hostProfile = bootstrapSystemdBootHostProfile;
            zfsOverlays = true;
          };

          zfsRuntime = mkNixosConfig {
            inherit
              profileModule
              catalog
              ;
            hostProfile = runtimeHostProfile;
            zfsOverlays = true;
          };

          runtimeExt4Modules = mkExt4ModulesFor runtimeHostProfile;
          runtimeExt4SpecialArgs = mkExt4SpecialArgsFor runtimeHostProfile runtimeExt4Modules;
          bringupSystemdBootExt4Modules = mkExt4ModulesFor bootstrapSystemdBootHostProfile;
          bringupSystemdBootExt4SpecialArgs = mkExt4SpecialArgsFor bootstrapSystemdBootHostProfile bringupSystemdBootExt4Modules;
          bringupGrubExt4Modules = mkExt4ModulesFor bringupGrubHostProfile;
          bringupGrubExt4SpecialArgs = mkExt4SpecialArgsFor bringupGrubHostProfile bringupGrubExt4Modules;

          # Canonical disk size in MiB shared by all disk-image profiles.
          # Keep one source of truth to avoid host/guest sizing drift.
          diskSizeMiB = (4 + 2) * 1024; # 4GiB base + 2GiB buffer for growth and closure size uncertainty
          diskSizeBytes = diskSizeMiB * 1024 * 1024;
          # Bringup closure paths used for stage-1/2 bootstrap sizing checks.
          bringupExt4SystemPath = ext4.config.system.build.toplevel;
          bringupZfsSystemPath = zfsBringup.config.system.build.toplevel;
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

          mkDiskImageDescriptorYaml =
            {
              attr,
              imageMode,
              bootLoader,
              diskSizeMiB,
              sourceOutPath,
            }:
            ''
              schemaVersion: 1
              kind: nixos-disk-image
              attr: ${attr}
              imageMode: ${imageMode}
              bootLoader: ${bootLoader}
              format: raw-efi
              imagePath: nixos.img
              sourceOutPath: ${sourceOutPath}
              diskSizeMiB: ${toString diskSizeMiB}
            '';

          mkDiskImageWithDescriptor =
            {
              attr,
              imageMode,
              bootLoader,
              diskSizeMiB,
              source,
            }:
            pkgsForLinux.runCommand "nixos-disk-image-with-descriptor-${attr}" { } ''
              set -euo pipefail
              mkdir -p "$out"

              if [[ -f "${source}/nixos.img" ]]; then
                ln -s "${source}/nixos.img" "$out/nixos.img"
              elif [[ -f "${source}" ]]; then
                ln -s "${source}" "$out/nixos.img"
              else
                echo "[flake][ERROR] unsupported disk image source shape for ${attr}: ${source}" >&2
                exit 1
              fi

              cat >"$out/descriptor.yaml" <<'EOF'
              ${mkDiskImageDescriptorYaml {
                inherit
                  attr
                  imageMode
                  bootLoader
                  diskSizeMiB
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

          diskImageBringupSystemdBootRaw = mkRawEfiImage {
            modules = bringupSystemdBootExt4Modules ++ [
              {
                nix.registry.nixpkgs.flake = nixpkgs;
                virtualisation.diskSize = diskSizeMiB;
              }
            ];
            specialArgs = bringupSystemdBootExt4SpecialArgs;
          };

          diskImageBringupGrubRaw = mkRawEfiImage {
            modules = bringupGrubExt4Modules ++ [
              {
                nix.registry.nixpkgs.flake = nixpkgs;
                virtualisation.diskSize = diskSizeMiB;
              }
            ];
            specialArgs = bringupGrubExt4SpecialArgs;
          };

          diskImageFullExt4Raw = mkRawEfiImage {
            modules = runtimeExt4Modules ++ [
              {
                nix.registry.nixpkgs.flake = nixpkgs;
                virtualisation.diskSize = diskSizeMiB;
              }
            ];
            specialArgs = runtimeExt4SpecialArgs;
          };

          diskImageBringupSystemdBoot = mkDiskImageWithDescriptor {
            attr = "nixosDiskImageBringupSystemdBoot";
            imageMode = "bootstrap";
            bootLoader = "systemd-boot";
            diskSizeMiB = diskSizeMiB;
            source = diskImageBringupSystemdBootRaw;
          };

          diskImageBringupGrub = mkDiskImageWithDescriptor {
            attr = "nixosDiskImageBringupGrub";
            imageMode = "bootstrap";
            bootLoader = "grub";
            diskSizeMiB = diskSizeMiB;
            source = diskImageBringupGrubRaw;
          };

          diskImageFullExt4 = mkDiskImageWithDescriptor {
            attr = "nixosDiskImage";
            imageMode = "full";
            bootLoader = "systemd-boot";
            diskSizeMiB = diskSizeMiB;
            source = diskImageFullExt4Raw;
          };

        in
        {
          inherit diskSizeHint;
          inherit diskSizeMiB;
          nixosConfigurations = {
            ext4Bringup = ext4;
            zfsBringup = zfsBringup;
            "${mainName}-nixos" = zfsRuntime;
          };
          inherit
            diskImageFullExt4
            diskImageBringupSystemdBoot
            diskImageBringupGrub
            ;
        };
    in
    rec {
      formatter = forAllSystems (
        system:
        let
          pkgs = pkgsFor { inherit system; };
          treefmtConfig = import ./treefmt.nix {
            inherit pkgs;
            projectRootFile = "flake.nix";
          };
        in
        inputs.treefmt-nix.lib.mkWrapper pkgs treefmtConfig
      );

      # Disable flake checks to avoid treefmt-nix API mismatch during evaluation
      checks = forAllSystems (_: { });

      # Expose package sets with all overlays applied for both platforms we build
      pkgs = {
        aarch64-darwin = pkgsForDarwin;
        aarch64-linux = pkgsForLinux;
      };

      legacyPackages = {
        aarch64-darwin = pkgsForDarwin;
        aarch64-linux = pkgsForLinux;
      };

      packages = forAllSystems (system: {
        io-nxmatic-nix-darwin-home-bringup-runtime-profile-holder = mkNdhBootstrapRuntimePackage system;
        io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer = mkNdhBootstrapProfileInstaller system;
      });

      apps = forAllSystems (
        system:
        let
          installer = mkNdhBootstrapProfileInstaller system;
        in
        {
          io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer = {
            type = "app";
            program = "${installer}/bin/io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer";
          };
        }
      );

      mkHostOutputs =
        {
          hostProfile,
          profileModule,
          darwinExtraModules ? [ ],
          nixosExtraModules ? [ ],
          ...
        }:
        let
          mainName =
            if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
              hostProfile.hostAlias
            else
              hostProfile.hostName;
          catalog = {
            caches = cacheTrust.caches;

            users = {
              work = {
                name = "stephane.lacoin";
                description = "Stephane Lacoin (aka nxmatic)";
                email = "stephane.lacoin@hyland.com";
              };

              committed = {
                name = "nxmatic";
                description = "Stephane Lacoin (aka nxmatic)";
                email = "stephane.lacoin@gmail.com";
              };
            };

            networks = {
              lan = {
                cidr = "192.168.1.0/24";
                domain = ".lan";
              };
              tailnet = {
                cidr = "100.64.0.0/10";
                domain = ".mammoth-skate.ts.net";
              };
              # Canonical cluster underlay contract from rke2lab netplan (@codebase)
              # Source of truth: rke2lab/netplan (ClusterNetworkBlueprint semantics)
              rke2labNetplan = {
                supernetCidr = "10.80.0.0/18";
                clusterPrefixLength = 21;
                vmnetNetworkName = "vmnet-br";
                clusters = {
                  bioskop = {
                    index = 0;
                    cidr = "10.80.0.0/21";
                    gateway = "10.80.0.1";
                  };
                  nikopol = {
                    index = 2;
                    cidr = "10.80.16.0/21";
                    gateway = "10.80.16.1";
                  };
                };
              };
            };

            hosts = {
              bioskop = [
                {
                  form = "baremetal";
                  networks = [
                    "lan"
                    "tailnet"
                  ];
                  builder = {
                    systems = [ "aarch64-darwin" ];
                    maxJobs = 8;
                    protocol = "ssh-ng";
                  };
                }
                {
                  form = "baremetal";
                  networks = [
                    "lan"
                    "tailnet"
                  ];
                  vm = {
                    kind = "qemu";
                    manager = "nix-darwin";
                  };
                  builder = {
                    systems = [ "aarch64-linux" ];
                    maxJobs = 8;
                    protocol = "ssh-ng";
                  };
                }
                {
                  form = "baremetal";
                  networks = [
                    "lan"
                    "tailnet"
                  ];
                  vm = {
                    kind = "vz";
                    manager = "lima";
                  };
                  builder = {
                    systems = [ "aarch64-linux" ];
                    maxJobs = 8;
                    protocol = "ssh-ng";
                  };
                }
              ];

              nikopol = [
                {
                  # nikopol runs as a Tart/VZ macOS VM and does NOT serve as a darwin builder itself; it offloads to remote builders
                  form = "vm";
                  networks = [
                    "lan"
                    "tailnet"
                  ];
                  vm = {
                    kind = "vz";
                    manager = "tart";
                  };
                  builder = null;
                }
                {
                  form = "vm";
                  networks = [
                    "lan"
                    "tailnet"
                  ];
                  vm = {
                    kind = "vz";
                    manager = "lima";
                  };
                  builder = {
                    systems = [ "aarch64-linux" ];
                    maxJobs = 8;
                    protocol = "ssh-ng";
                  };
                }
              ];
            };
          };

          workHomeManagerUser =
            if hostProfile ? homeManagerUser && hostProfile.homeManagerUser != null then
              hostProfile.homeManagerUser
            else
              catalog.users.work;
          workHomeManagerUserWithHome = workHomeManagerUser // {
            home =
              if workHomeManagerUser ? home && workHomeManagerUser.home != null then
                workHomeManagerUser.home
              else
                "/Users/${workHomeManagerUser.name}";
          };
          committedHomeManagerUserWithHome = catalog.users.committed // {
            home =
              if catalog.users.committed ? home && catalog.users.committed.home != null then
                catalog.users.committed.home
              else
                "/Users/${catalog.users.committed.name}";
          };
          workProfile = {
            name = "work";
            sshKeyProfileName = "committed";
            host = hostProfile;
            user = workHomeManagerUserWithHome;
            email = workHomeManagerUserWithHome.email;
          };
          committedProfile = {
            name = "committed";
            host = hostProfile;
            user = committedHomeManagerUserWithHome;
            email = committedHomeManagerUserWithHome.email;
          };
          nixosOutputs = mkNixosOutputs {
            inherit hostProfile catalog;
            profileModule =
              { ... }:
              {
                imports = [ profileModule ] ++ nixosExtraModules;
              };
          };
          nixosConfiguration = nixosOutputs.nixosConfigurations."${mainName}-nixos";
          nixosDiskImage = nixosOutputs.diskImageFullExt4;
          nixosDiskImageBringupSystemdBoot = nixosOutputs.diskImageBringupSystemdBoot;
          nixosDiskImageBringupGrub = nixosOutputs.diskImageBringupGrub;
          nixosDiskSizeHint = nixosOutputs.diskSizeHint;
          nixosDiskSizeMiB = nixosOutputs.diskSizeMiB;
          mkHomeManagerConfig =
            profile:
            home-manager.lib.homeManagerConfiguration {
              pkgs = pkgsForDarwin;
              modules = [
                ./modules/home-manager
                (
                  { lib, ... }:
                  {
                    home.username = lib.mkDefault profile.user.name;
                    home.homeDirectory = lib.mkDefault (toString profile.user.home);
                  }
                )
              ];
              extraSpecialArgs = {
                inherit hostProfile catalog;
                inherit profile;
                logger = mkLoggerSpecialArg "aarch64-darwin";
                ndh = {
                  store = ndhStoreApiDarwin;
                };
                sshKeysYamlPath = "${toString profile.user.home}/.local/var/run/secrets/sops/ssh-keys.yaml";
                limaConfigMaterializerPackage =
                  darwinOutputs.darwinConfigurations.${mainName}.config.lima.configGenerator.materializerPackage;
              };
            };
          darwinOutputs = mkDarwinOutputs {
            inherit hostProfile catalog;
            profileModule =
              { lib, ... }:
              {
                imports = [
                  profileModule
                  (
                    { ... }:
                    {
                      lima.configGenerator.imageDescriptorPath = "${nixosDiskImageBringupSystemdBoot}/descriptor.yaml";
                      lima.configGenerator.imageStorePath = "${nixosDiskImageBringupSystemdBoot}/nixos.img";
                      lima.configGenerator.diskSizeGiB = builtins.div nixosDiskSizeMiB 1024;
                    }
                  )
                ]
                ++ darwinExtraModules;
              };
          };
          darwinConfiguration = darwinOutputs.darwinConfigurations.${mainName};
          autofsNetMaterializerPackage =
            if
              darwinConfiguration ? config
              && darwinConfiguration.config ? services
              && darwinConfiguration.config.services ? nfsDarwin
              && darwinConfiguration.config.services.nfsDarwin ? autofs
              && darwinConfiguration.config.services.nfsDarwin.autofs ? materializerPackage
            then
              darwinConfiguration.config.services.nfsDarwin.autofs.materializerPackage
            else
              null;
          autofsNetMaterializerProgram =
            if autofsNetMaterializerPackage != null then
              "${autofsNetMaterializerPackage}/bin/nfs-autofs-net-materialize"
            else
              null;
          ndhBootstrapRuntimePackage = mkNdhBootstrapRuntimePackage "aarch64-darwin";
          ndhBootstrapInstallerPackage = mkNdhBootstrapProfileInstaller "aarch64-darwin";
          ndhBootstrapRuntimePackageLinux = mkNdhBootstrapRuntimePackage "aarch64-linux";
          ndhBootstrapInstallerPackageLinux = mkNdhBootstrapProfileInstaller "aarch64-linux";
          ndhPrerequisitesInstallerScriptSource =
            pkgsForDarwin.replaceVars ./modules/.common.d/bootstrap-profile.d/prerequisites-install-wrapper.sh
              {
                bash = "${pkgsForDarwin.bash}/bin/bash";
                bashTrampoline = "${./modules/.common.d/shell.d/nix-bash-trampoline.sh}";
                logger = (mkLoggerSpecialArg "aarch64-darwin").script;
                loggerTag = "ndh.bootstrap-profile.prerequisites-install.darwin";
                autofsMaterializerProgram =
                  if autofsNetMaterializerProgram != null then autofsNetMaterializerProgram else "";
                standaloneInstaller = "${ndhBootstrapInstallerPackage}/bin/io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer";
              };
          ndhPrerequisitesInstallerScriptSourceLinux =
            pkgsForLinux.replaceVars ./modules/.common.d/bootstrap-profile.d/prerequisites-install-wrapper.sh
              {
                bash = "${pkgsForLinux.bash}/bin/bash";
                bashTrampoline = "${./modules/.common.d/shell.d/nix-bash-trampoline.sh}";
                logger = (mkLoggerSpecialArg "aarch64-linux").script;
                loggerTag = "ndh.bootstrap-profile.prerequisites-install.linux";
                autofsMaterializerProgram = "";
                standaloneInstaller = "${ndhBootstrapInstallerPackageLinux}/bin/io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer";
              };
          ndhPrerequisitesInstallerPackage = ndhStoreApiDarwin.runCommand "prerequisites-install" { } ''
            install -Dm755 ${ndhPrerequisitesInstallerScriptSource} "$out/bin/io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer"
          '';
          ndhPrerequisitesInstallerPackageLinux = ndhStoreApiLinux.runCommand "prerequisites-install" { } ''
            install -Dm755 ${ndhPrerequisitesInstallerScriptSourceLinux} "$out/bin/io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer"
          '';
          hostDarwinPackages = {
            io-nxmatic-nix-darwin-home-bringup-runtime-profile-holder = ndhBootstrapRuntimePackage;
            io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer = ndhPrerequisitesInstallerPackage;
          };
          hostLinuxPackages = {
            io-nxmatic-nix-darwin-home-bringup-runtime-profile-holder = ndhBootstrapRuntimePackageLinux;
            io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer =
              ndhPrerequisitesInstallerPackageLinux;
          };
          hostDarwinApps = {
            io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer = {
              type = "app";
              program = "${ndhPrerequisitesInstallerPackage}/bin/io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer";
            };
          };
          hostLinuxApps = {
            io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer = {
              type = "app";
              program = "${ndhPrerequisitesInstallerPackageLinux}/bin/io-nxmatic-nix-darwin-home-bringup-runtime-profile-installer";
            };
          };

          # Home Manager configurations are explicitly profile-keyed.
          homeManagerConfigurations = {
            work = mkHomeManagerConfig workProfile;
            bringup = mkHomeManagerConfig workProfile;
            committed = mkHomeManagerConfig committedProfile;
          };
        in
        nixosOutputs
        // darwinOutputs
        // {
          inherit
            darwinConfiguration
            nixosConfiguration
            nixosDiskImage
            nixosDiskImageBringupSystemdBoot
            nixosDiskImageBringupGrub
            nixosDiskSizeHint
            homeManagerConfigurations
            ;
          homeManagerConfiguration = homeManagerConfigurations.committed;
          pkgs = {
            darwin = pkgsForDarwin;
            linux = pkgsForLinux;
          };

          packages =
            nixpkgs.lib.optionalAttrs (hostDarwinPackages != { }) {
              aarch64-darwin = hostDarwinPackages;
            }
            // nixpkgs.lib.optionalAttrs (hostLinuxPackages != { }) {
              aarch64-linux = hostLinuxPackages;
            };

          apps =
            nixpkgs.lib.optionalAttrs (hostDarwinApps != { }) {
              aarch64-darwin = hostDarwinApps;
            }
            // nixpkgs.lib.optionalAttrs (hostLinuxApps != { }) {
              aarch64-linux = hostLinuxApps;
            };

          defaultPackage."aarch64-darwin" = darwinConfiguration.system;
        };

      hostOutputs =
        let
          bioskopSpec = import ./hosts/bioskop;
          nikopolSpec = import ./hosts/nikopol;
        in
        {
          bioskop = mkHostOutputs bioskopSpec;
          nikopol = mkHostOutputs nikopolSpec;
        };

      darwinConfigurations =
        hostOutputs.bioskop.darwinConfigurations
        // hostOutputs.nikopol.darwinConfigurations;

      nixosConfigurations =
        hostOutputs.bioskop.nixosConfigurations
        // hostOutputs.nikopol.nixosConfigurations;

      homeManagerConfigurations = {
        bioskop = hostOutputs.bioskop.homeManagerConfigurations;
        nikopol = hostOutputs.nikopol.homeManagerConfigurations;
      };

      nixosDiskImages = {
        bioskop = {
          full = hostOutputs.bioskop.nixosDiskImage;
          bringupSystemdBoot = hostOutputs.bioskop.nixosDiskImageBringupSystemdBoot;
          bringupGrub = hostOutputs.bioskop.nixosDiskImageBringupGrub;
        };
        nikopol = {
          full = hostOutputs.nikopol.nixosDiskImage;
          bringupSystemdBoot = hostOutputs.nikopol.nixosDiskImageBringupSystemdBoot;
          bringupGrub = hostOutputs.nikopol.nixosDiskImageBringupGrub;
        };
      };

      overlays = {
        channels = inputs: final: prev: {
          nixpkgs = import inputs.nixpkgs {
            system = prev.stdenv.hostPlatform.system;
          };
        };

        extraPackages =
          inputs: final: prev:
          let
            hostSystem = prev.stdenv.hostPlatform.system;
          in
          {
            #inherit (self.packages.${hostSystem}) sysdo pyEnv;
            #inherit (inputs.devenv.packages.${hostSystem}) devenv;

            # rancher-desktop = final.callPackage ./pkgs/rancher-desktop.nix {};
            inherit (inputs.maven-mvnd.packages.${hostSystem}) maven-mvnd-m39;
            inherit (inputs.disko.packages.${hostSystem}) disko;
            inherit (inputs.incus-compose.packages.${hostSystem}) incus-compose;
          };

        birdOverlay = inputs: import ./overlays/bird.nix inputs;
        qemuOverlay = inputs: import ./overlays/qemu.nix inputs;
        nodejsOverlay = inputs: import ./overlays/nodejs.nix inputs;
        incusComposeOverlay = inputs: import ./overlays/incus-compose.nix inputs;
        lazygitOverlay = inputs: import ./overlays/lazygit.nix inputs;
        limaOverlay = inputs: import ./overlays/lima.nix inputs;
        tailscaleOverlay = inputs: import ./overlays/tailscale.nix inputs;
      };

      homeManagerModules = {
        primaryUser = import ./modules/.common.d/primary-user.nix;
        manager = import ./modules/home-manager;
        profiles = {
          # Optionally, expose profiles as modules if they are home-manager compatible
          work = import ./profiles/work.nix;
          committed = import ./profiles/committed.nix;
        };
      };

      # Development shells (add docs environment with diagram support)
      devShells = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
            };
          };
        in
        {
          docs = pkgs.mkShell {
            packages = with pkgs; [
              asciidoctor-with-extensions
              plantuml
              graphviz
              # Optional: dot for Graphviz is already in graphviz
            ];
            shellHook = ''
              echo "Docs dev shell active (system: ${system})."
              echo "Run: modules/nixos/rke2lab/bin/generate-docs.sh"
            '';
          };
        }
      );

    };
}
