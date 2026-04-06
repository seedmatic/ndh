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
      "nxmatic.cachix.org-1:oWogvXdam3gTxKzPZCDqq8khybQpqRdNpQQrKG3r4xM="
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
    nixos-generators.follows = "flake-commons/nixos-generators";
    incus-compose.follows = "flake-commons/incus-compose";
    sops-nix.url = "github:Mic92/sops-nix";
  };

  outputs =
    {
      self,
      darwin,
      devenv,
      flake-utils,
      nixos-generators,
      home-manager,
      disko,
      socket-vmnet,
      impermanence,
      nixpkgs,
      ...
    }@inputs:
    let
      inherit (flake-utils.lib) eachSystemMap;
      nixpkgsConfig = import ./modules/common/nixpkgs-config.nix;
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

      mkBaseModulesFor =
        { hostProfile, system }:
        let
          hostImageMode =
            if hostProfile ? nixosImageMode && hostProfile.nixosImageMode != null then
              hostProfile.nixosImageMode
            else
              "full";
          bringupModeInternal = hostImageMode == "bootstrap";
          requestedHomeManagerEnabled =
            if hostProfile ? enableHomeManager && hostProfile.enableHomeManager != null then
              hostProfile.enableHomeManager
            else
              true;
          homeManagerEnabled =
            if system == "nixos" && bringupModeInternal then
              false
            else
              requestedHomeManagerEnabled;
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
          loggerScript = pkgsForSystem.writeText "logger.sh" ''
            #!/usr/bin/env bash
            LOGGER_CMD=""
            source ${./modules/common/shell.d/logger.sh}
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
        in
        pkgsForSystem.symlinkJoin {
          name = "ndh-bootstrap-runtime";
          paths = with pkgsForSystem; [
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
          runtimePackage = mkNdhBootstrapRuntimePackage system;
          scriptSource = pkgsForSystem.replaceVars ./modules/common/bootstrap-profile.d/install-standalone.sh {
            runtimePackage = runtimePackage;
            defaultProfileDir = "\${HOME}/.local/state/nix/profiles/ndh-bootstrap-runtime";
            requiredCommands = "age age-keygen awk sed grep ssh ssh-keygen yq git";
          };
        in
        pkgsForSystem.writeShellScriptBin "ndh-bootstrap-profile-install" (builtins.readFile scriptSource);

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
          hostImageMode =
            if hostProfile ? nixosImageMode && hostProfile.nixosImageMode != null then
              hostProfile.nixosImageMode
            else
              "full";
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
          ] ++ (if bringupModeInternal then [ ] else [ nixosTailscaleTagModule ]);
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
          hostImageMode =
            if hostProfile ? nixosImageMode && hostProfile.nixosImageMode != null then
              hostProfile.nixosImageMode
            else
              "full";
          _ =
            assert builtins.elem hostImageMode [
              "full"
              "bootstrap"
            ];
            true;

          mkExt4ModulesFor =
            hp:
            let
              hpImageMode =
                if hp ? nixosImageMode && hp.nixosImageMode != null then
                  hp.nixosImageMode
                else
                  "full";
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
              ] ++ (if hpBringupModeInternal then [ ] else [ nixosTailscaleTagModule ]);
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

          selectedHostProfile =
            hostProfile
            // {
              nixosImageMode = hostImageMode;
            };

          runtimeHostProfile =
            hostProfile
            // {
              nixosImageMode = "full";
              nixosBootLoader = "systemd-boot";
            };

          bringupSystemdBootHostProfile =
            hostProfile
            // {
              nixosImageMode = "bootstrap";
              bootstrapDebug = true;
              nixosBootLoader = "systemd-boot";
            };

          bringupGrubHostProfile =
            hostProfile
            // {
              nixosImageMode = "bootstrap";
              bootstrapDebug = true;
              nixosBootLoader = "grub";
            };

          ext4Modules = mkExt4ModulesFor selectedHostProfile;
          ext4SpecialArgs = mkExt4SpecialArgsFor selectedHostProfile ext4Modules;

          ext4 = nixpkgs.lib.nixosSystem {
            modules = ext4Modules;
            specialArgs = ext4SpecialArgs;
            system = "aarch64-linux";
            pkgs = pkgsForLinux;
          };

          zfs = mkNixosConfig {
            inherit
              profileModule
              catalog
              ;
            hostProfile = runtimeHostProfile;
            zfsOverlays = true;
          };

          runtimeExt4Modules = mkExt4ModulesFor runtimeHostProfile;
          runtimeExt4SpecialArgs = mkExt4SpecialArgsFor runtimeHostProfile runtimeExt4Modules;
          bringupSystemdBootExt4Modules = mkExt4ModulesFor bringupSystemdBootHostProfile;
          bringupSystemdBootExt4SpecialArgs =
            mkExt4SpecialArgsFor bringupSystemdBootHostProfile bringupSystemdBootExt4Modules;
          bringupGrubExt4Modules = mkExt4ModulesFor bringupGrubHostProfile;
          bringupGrubExt4SpecialArgs = mkExt4SpecialArgsFor bringupGrubHostProfile bringupGrubExt4Modules;

          # Disk sizes in MiB
          # - runtime/systemd-boot bringup: safe size for full closure population
          # - bringup-grub: reduced-size image for fast iteration/debug
          diskSizeFullMiB = 12 * 1024;
          diskSizeBringupSystemdBootMiB = 12 * 1024;
          diskSizeBringupGrubMiB = 8 * 1024;
          diskSizeBytes = diskSizeFullMiB * 1024 * 1024;
          # System closure path
          systemPath = zfs.config.system.build.toplevel;
          # Output a JSON hint with all relevant info for post-build checks
          diskSizeHint = builtins.toJSON {
            systemPath = systemPath;
            diskSizeBytes = diskSizeBytes;
            diskSizeMiB = {
              runtime = diskSizeFullMiB;
              bringupSystemdBoot = diskSizeBringupSystemdBootMiB;
              bringupGrub = diskSizeBringupGrubMiB;
            };
            hint = "nix path-info -Sh ${systemPath}";
            note = "closure size should be less than diskSizeBytes";
          };
          mainName =
            if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
              hostProfile.hostAlias
            else
              hostProfile.hostName;

          diskImageBringupSystemdBoot = nixos-generators.nixosGenerate {
            modules = bringupSystemdBootExt4Modules ++ [
              {
                nix.registry.nixpkgs.flake = nixpkgs;
                virtualisation.diskSize = diskSizeBringupSystemdBootMiB;
              }
            ];
            specialArgs = bringupSystemdBootExt4SpecialArgs;
            system = "aarch64-linux";
            pkgs = pkgsForLinux;
            format = "raw-efi";
          };

          diskImageBringupGrub = nixos-generators.nixosGenerate {
            modules = bringupGrubExt4Modules ++ [
              {
                nix.registry.nixpkgs.flake = nixpkgs;
                virtualisation.diskSize = diskSizeBringupGrubMiB;
              }
            ];
            specialArgs = bringupGrubExt4SpecialArgs;
            system = "aarch64-linux";
            pkgs = pkgsForLinux;
            format = "raw-efi";
          };

        in
        {
          inherit diskSizeHint;
          nixosConfigurations = {
            inherit ext4 zfs;
            "${mainName}-nixos" = if hostImageMode == "bootstrap" then ext4 else zfs;
          };
          inherit
            diskImageBringupSystemdBoot
            diskImageBringupGrub
            ;
        };
    in
    {
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
        ndh-bootstrap-runtime = mkNdhBootstrapRuntimePackage system;
        ndh-prerequisites-install = mkNdhBootstrapProfileInstaller system;
      });

      apps = forAllSystems (system:
        let
          installer = mkNdhBootstrapProfileInstaller system;
        in
        {
          ndh-prerequisites-install = {
            type = "app";
            program = "${installer}/bin/ndh-bootstrap-profile-install";
          };
          ndh-bootstrap-runtime = {
            type = "app";
            program = "${installer}/bin/ndh-bootstrap-profile-install";
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
                name = "nxmatic";
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

          defaultProfile = {
            name = mainName;
            host = hostProfile;
            user = catalog.users.committed // {
              home = "/Users/${catalog.users.committed.name}";
            };
          };
          darwinOutputs = mkDarwinOutputs {
            inherit hostProfile catalog;
            profileModule =
              { ... }:
              {
                imports = [ profileModule ] ++ darwinExtraModules;
              };
          };
          darwinConfiguration = darwinOutputs.darwinConfigurations.${mainName};

          nixosOutputs = mkNixosOutputs {
            inherit hostProfile catalog;
            profileModule =
              { ... }:
              {
                imports = [ profileModule ] ++ nixosExtraModules;
              };
          };
          nixosConfiguration = nixosOutputs.nixosConfigurations."${mainName}-nixos";
          nixosDiskImageBringupSystemdBoot = nixosOutputs.diskImageBringupSystemdBoot;
          nixosDiskImageBringupGrub = nixosOutputs.diskImageBringupGrub;
          nixosDiskSizeHint = nixosOutputs.diskSizeHint;
          limaMaterializerPackage =
            if darwinConfiguration ? config
              && darwinConfiguration.config ? lima
              && darwinConfiguration.config.lima ? configGenerator
              && darwinConfiguration.config.lima.configGenerator ? materializerPackage then
              darwinConfiguration.config.lima.configGenerator.materializerPackage
            else
              null;
          limaMaterializerProgram =
            if limaMaterializerPackage != null then
              "${limaMaterializerPackage}/bin/lima-config-materialize"
            else
              null;
          autofsNetMaterializerPackage =
            if darwinConfiguration ? config
              && darwinConfiguration.config ? services
              && darwinConfiguration.config.services ? nfsDarwin
              && darwinConfiguration.config.services.nfsDarwin ? autofs
              && darwinConfiguration.config.services.nfsDarwin.autofs ? materializerPackage then
              darwinConfiguration.config.services.nfsDarwin.autofs.materializerPackage
            else
              null;
          autofsNetMaterializerProgram =
            if autofsNetMaterializerPackage != null then
              "${autofsNetMaterializerPackage}/bin/nfs-autofs-net-materialize"
            else
              null;
          limaMaterializerAppProgram =
            if limaMaterializerProgram != null && autofsNetMaterializerProgram != null then
              "${pkgsForDarwin.writeShellScript "lima-config-materialize-app" ''
                #!/usr/bin/env bash
                set -euo pipefail

                /usr/bin/sudo ${autofsNetMaterializerProgram}
                exec ${limaMaterializerProgram} "$@"
              ''}"
            else
              limaMaterializerProgram;
          ndhBootstrapRuntimePackage = mkNdhBootstrapRuntimePackage "aarch64-darwin";
          ndhBootstrapInstallerPackage = mkNdhBootstrapProfileInstaller "aarch64-darwin";
          ndhPrerequisitesInstallerPackage =
            pkgsForDarwin.writeShellScriptBin "ndh-prerequisites-install" ''
              #!/usr/bin/env bash
              set -euo pipefail

              ${nixpkgs.lib.optionalString (autofsNetMaterializerProgram != null) "/usr/bin/sudo ${autofsNetMaterializerProgram}"}
              exec ${ndhBootstrapInstallerPackage}/bin/ndh-bootstrap-profile-install "$@"
            '';
          hostDarwinPackages =
            (nixpkgs.lib.optionalAttrs (limaMaterializerPackage != null) {
              lima-config-materialize = limaMaterializerPackage;
            })
            // {
              ndh-bootstrap-runtime = ndhBootstrapRuntimePackage;
              ndh-prerequisites-install = ndhPrerequisitesInstallerPackage;
            };
          hostDarwinApps =
            (nixpkgs.lib.optionalAttrs (limaMaterializerAppProgram != null) {
              lima-config-materialize = {
                type = "app";
                program = limaMaterializerAppProgram;
              };
            })
            // {
              ndh-prerequisites-install = {
                type = "app";
                program = "${ndhPrerequisitesInstallerPackage}/bin/ndh-prerequisites-install";
              };
              ndh-bootstrap-runtime = {
                type = "app";
                program = "${ndhPrerequisitesInstallerPackage}/bin/ndh-prerequisites-install";
              };
            };

          # Home Manager configurations for direct use
          homeManagerConfigurations =
            {
              "${mainName}" = home-manager.lib.homeManagerConfiguration {
                pkgs = pkgsForDarwin;
                modules = [ ./modules/home-manager ];
                extraSpecialArgs = {
                  inherit hostProfile catalog;
                  profile = defaultProfile;
                  logger = mkLoggerSpecialArg "aarch64-darwin";
                };
                # Optionally, set username and homeDirectory here if needed
              };
            };
        in
        nixosOutputs
        // darwinOutputs
        // {
          inherit
            darwinConfiguration
            nixosConfiguration
            nixosDiskImageBringupSystemdBoot
            nixosDiskImageBringupGrub
            nixosDiskSizeHint
            homeManagerConfigurations
            ;
          pkgs = {
            darwin = pkgsForDarwin;
            linux = pkgsForLinux;
          };

          packages = nixpkgs.lib.optionalAttrs (hostDarwinPackages != { }) {
            aarch64-darwin = hostDarwinPackages;
          };

          apps = nixpkgs.lib.optionalAttrs (hostDarwinApps != { }) {
            aarch64-darwin = hostDarwinApps;
          };

          defaultPackage."aarch64-darwin" = darwinConfiguration.system;
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
        primaryUser = import ./modules/common/primary-user.nix;
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
